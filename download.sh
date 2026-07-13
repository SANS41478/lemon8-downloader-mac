#!/bin/bash
# 🍋 Lemon8 Batch Image Downloader (macOS)
# 真正零依赖 — 只用系统自带的 curl + osascript (JavaScript)
#
# Usage:
#   bash download.sh
#   bash download.sh -f urls.txt -o images -p http://127.0.0.1:7897
#   bash download.sh "URL" -p http://127.0.0.1:7897

set -euo pipefail

URL_FILE="urls.txt"
OUTPUT_DIR="images"
PROXY=""
SINGLE_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)   URL_FILE="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -p|--proxy)  PROXY="$2"; shift 2 ;;
        -h|--help)
            cat << 'EOF'
Lemon8 Batch Image Downloader (macOS)
Usage:
  bash download.sh
  bash download.sh -f urls.txt -o images -p http://127.0.0.1:7897
  bash download.sh "URL" -p http://127.0.0.1:7897
Options:
  -f, --file    URL list file (one per line, # for comments)
  -o, --output  Output directory (default: images)
  -p, --proxy   HTTP proxy, e.g. http://127.0.0.1:7897
  -h, --help    Show this help
EOF
            exit 0
            ;;
        -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)  SINGLE_URL="$1"; shift ;;
    esac
done

# ==================== Prerequisites ====================
if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required." >&2; exit 1
fi
if ! command -v osascript &>/dev/null; then
    echo "ERROR: This script requires macOS (osascript not found)." >&2; exit 1
fi

# ==================== Color helpers ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
red()    { echo -e "${RED}$*${NC}"; }
green()  { echo -e "${GREEN}$*${NC}"; }
yellow() { echo -e "${YELLOW}$*${NC}"; }

# ==================== Curl helpers ====================
CURL_OPTS=(-s -L --max-time 60 --connect-timeout 15
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")

if [[ -n "$PROXY" ]]; then
    case "$PROXY" in
        http://*|https://*|socks4://*|socks5://*) ;;
        *) PROXY="http://$PROXY" ;;
    esac
    CURL_OPTS+=(-x "$PROXY")
fi

curl_page_to_file() {
    curl "${CURL_OPTS[@]}" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,th;q=0.8,zh;q=0.7" \
        --max-time 30 -o "$2" "$1"
}

curl_download() {
    local url="$1" dest="$2" retries=3 i
    for ((i=retries; i>=0; i--)); do
        if curl "${CURL_OPTS[@]}" \
            -H "Referer: https://www.lemon8-app.com/" \
            -H "Accept: image/webp,image/*,*/*;q=0.8" \
            --max-time 120 -o "$dest" "$url" 2>/dev/null; then
            [[ -f "$dest" ]] && [[ $(wc -c < "$dest" 2>/dev/null || echo 0) -gt 0 ]] && return 0
        fi
        rm -f "$dest"
        (( i > 0 )) && printf " (retry %d...)" "$i" && sleep 2
    done
    return 1
}

# ==================== JXA 引擎 ====================
# 所有 JSON 操作统一走 osascript JavaScript（macOS 自带，零依赖）
# 输出不依赖 stdout（JXA 下不可靠），改为写临时文件

JXA_HELPER=$(mktemp)
cat > "$JXA_HELPER" << 'JXAEOF'
ObjC.import('Foundation');

function readFile(p) {
    var s=$.NSString.stringWithContentsOfFileEncodingError($(p),$.NSUTF8StringEncoding,null);
    if(!s||!s.js)throw new Error('Cannot read: '+p); return s.js;
}
function writeFile(p,content) {
    $.NSString.stringWithString($(String(content))).writeToFileAtomicallyEncodingError($(p),true,$.NSUTF8StringEncoding,null);
}

var argv=[];
if(typeof arguments!=='undefined')argv=Array.prototype.slice.call(arguments);
if(argv.length===0){
    var a=$.NSProcessInfo.processInfo.arguments;
    for(var i=0;i<a.count;i++)argv.push(a.objectAtIndex(i).js);
    var d=argv.indexOf('--'); if(d!==-1)argv=argv.slice(d+1);
}
var mode=argv[0]||'extract';

// ---------- extract ----------
if(mode==='extract'){
    var html=readFile(argv[1]);
    var re=/<script\s+type="application\/json"\s+data-ttark="__remixContext"[^>]*>([\s\S]*?)<\/script>/;
    var m=html.match(re);
    if(!m){ re=/data-ttark="__remixContext"[^>]*>\s*([\s\S]*?)\s*<\/script>/; m=html.match(re); }
    if(!m)throw new Error('Cannot find __remixContext');

    var decoded=decodeURIComponent(m[1].trim());
    var data=JSON.parse(decoded);
    var ld=(data.state||{}).loaderData||{};
    if(Object.keys(ld).length===0)throw new Error('No loaderData');

    var article=null;
    // 策略 1: user_link_name 路由
    for(var k in ld){
        if(k.indexOf('user_link_name')!==-1&&typeof ld[k]==='object'){
            var r=ld[k];
            for(var ak in r){ if(typeof r[ak]==='object'&&(r[ak].imageList||r[ak].articleClass||r[ak].largeImage)){article=r[ak];break;} }
            if(!article&&(r.imageList||r.articleClass))article=r;
            break;
        }
    }
    // 策略 2: 遍历嵌套
    if(!article){for(var k in ld){if(typeof ld[k]!=='object')continue;for(var ak in ld[k]){if(typeof ld[k][ak]==='object'&&(ld[k][ak].imageList||ld[k][ak].largeImage)){article=ld[k][ak];break;}}if(article)break;}}
    // 策略 3: 直接在 loaderData 下
    if(!article){for(var k in ld){if(typeof ld[k]==='object'&&(ld[k].imageList||ld[k].largeImage)){article=ld[k];break;}}}
    // unavailable 检测
    if(!article){for(var k in ld){var v=ld[k];if(typeof v==='object'){for(var ak in v){if(typeof v[ak]==='object'&&v[ak].unavailableReason)throw new Error('Article unavailable (reason: '+v[ak].unavailableReason+')');}}}
        throw new Error('Cannot find article. loaderData keys: '+Object.keys(ld).join(', '));}

    var title=String(article.title||'untitled');
    var author='unknown';
    if(article.author&&typeof article.author==='object')author=String(article.author.nickName||article.author.nickname||'unknown');
    var cls=String(article.articleClass||'Unknown');
    var imgs=article.imageList||[];
    var lg=article.largeImage||null;

    function makeHiRes(u){ return u.replace(/~tplv-[^./]+/,'~tplv-sdweummd6v-origin'); }
    function genAlt(u){ var a=[u]; if(u.indexOf('tiktokcdn.com')!==-1){var b=u.replace(/p16-lemon8-(sign|cross-sign)-sg\.tiktokcdn\.com/,'p16-sign-sg.lemon8cdn.com');if(b!==u)a.push(b);} return a; }
    function dedup(a){var s={};return a.filter(function(x){return x&&!(x in s)?(s[x]=true):false;});}

    var result=[];
    if(cls==='Gallery'&&imgs.length>0){
        for(var i=0;i<imgs.length;i++){
            var url=imgs[i].url||'', hi=makeHiRes(url), pts=[url];
            if(hi&&hi!==url)pts=pts.concat(genAlt(hi));
            genAlt(url).forEach(function(u){if(u!==url&&pts.indexOf(u)===-1)pts.push(u);});
            pts=dedup(pts);
            result.push({index:i,url:url,altUrls:pts.slice(1),width:imgs[i].width||0,height:imgs[i].height||0,type:'gallery'});
        }
    }else if(cls==='Video'&&lg){
        var url=lg.url||'', hi=makeHiRes(url), pts=[url];
        if(hi&&hi!==url)pts=pts.concat(genAlt(hi));
        genAlt(url).forEach(function(u){if(u!==url&&pts.indexOf(u)===-1)pts.push(u);});
        pts=dedup(pts);
        result.push({index:0,url:url,altUrls:pts.slice(1),width:lg.width||0,height:lg.height||0,type:'video_cover'});
    }

    var out={title:title,author:author,articleClass:cls,imageCount:result.length,images:result};
    writeFile(argv[2],JSON.stringify(out));
}

// ---------- fields ----------
else if(mode==='fields'){
    var art=JSON.parse(readFile(argv[1]));
    var lines=[];
    lines.push('MGTITLE='+JSON.stringify(String(art.title||'untitled')));
    lines.push('MGAUTHOR='+JSON.stringify(String(art.author||'unknown')));
    lines.push('MGCLASS='+JSON.stringify(String(art.articleClass||'Unknown')));
    lines.push('MGCOUNT='+art.imageCount);
    writeFile(argv[2],lines.join('\n'));
}

// ---------- meta ----------
else if(mode==='meta'){
    var images=JSON.parse(readFile(argv[1]));
    var meta={
        url:           $.NSProcessInfo.processInfo.environment.objectForKey('META_URL').js||'',
        username:      $.NSProcessInfo.processInfo.environment.objectForKey('META_USERNAME').js||'',
        articleId:     $.NSProcessInfo.processInfo.environment.objectForKey('META_ARTICLE_ID').js||'',
        title:         $.NSProcessInfo.processInfo.environment.objectForKey('META_TITLE').js||'',
        author:        $.NSProcessInfo.processInfo.environment.objectForKey('META_AUTHOR').js||'',
        articleClass:  $.NSProcessInfo.processInfo.environment.objectForKey('META_ARTICLE_CLASS').js||'',
        imageCount:    images.length,
        downloadedAt:  $.NSProcessInfo.processInfo.environment.objectForKey('META_DOWNLOADED_AT').js||'',
        proxy:         $.NSProcessInfo.processInfo.environment.objectForKey('META_PROXY').js||'direct',
        images:        images.map(function(img,i){
            var n=String(i+1); while(n.length<2)n='0'+n;
            return {index:img.index,width:img.width,height:img.height,url:img.url,filename:n+'_'+img.width+'x'+img.height+'.webp'};
        })
    };
    var dest=$.NSProcessInfo.processInfo.environment.objectForKey('META_DEST').js||'meta.json';
    writeFile(dest,JSON.stringify(meta,null,2));
}

// ---------- pick ----------
else if(mode==='pick'){
    var d=$.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile();
    var s=$.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding).js;
    if(!s)throw new Error('No stdin');
    var obj=JSON.parse(s), field=argv[1];
    var m2=field.match(/^\[(\d+)\]$/);
    var val;
    if(m2){ val=obj[parseInt(m2[1])]; }
    else {
        val=field.split('.').reduce(function(o,k){
            var am=k.match(/^(.+)\[(\d+)\]$/);
            if(am){var arr=(o||{})[am[1]];return arr?arr[parseInt(am[2])]:null;}
            return (o||{})[k];
        },obj);
    }
    if(val===undefined||val===null)val='';
    else if(typeof val==='object')val=JSON.stringify(val);
    else val=String(val);
    writeFile(argv[2],val);
}

else { throw new Error('Unknown mode: '+mode); }
JXAEOF

cleanup() { rm -f "$JXA_HELPER"; }
trap cleanup EXIT

# ==================== Helpers ====================

safe_folder_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//' | head -c 80
}

parse_url() {
    local url="$1"
    if [[ "$url" =~ lemon8-app\.com/@([^/]+)/([0-9]+) ]]; then
        local username="${BASH_REMATCH[1]}" article_id="${BASH_REMATCH[2]}" region="th"
        [[ "$url" =~ region=([a-z]+) ]] && region="${BASH_REMATCH[1]}"
        echo "$username|$article_id|$region|$url"
    else
        return 1
    fi
}

# ==================== Post Processor ====================

process_post() {
    local url="$1" output_root="$2"

    echo ""
    printf "=%.0s" {1..55}
    echo ""

    local parsed
    if ! parsed=$(parse_url "$url"); then
        red "   ERROR: Cannot parse URL: $url"
        echo "FAIL:parse|unknown|$url"
        return 0
    fi

    IFS='|' read -r username article_id region original_url <<< "$parsed"
    echo "[$username] $article_id"
    echo "   URL: $url"

    # 1. Fetch page
    printf "   Fetching page..."
    local html_file=$(mktemp)
    if ! curl_page_to_file "$url" "$html_file" || [[ ! -s "$html_file" ]]; then
        rm -f "$html_file"
        red " ERROR: Failed to fetch page"
        [[ -z "$PROXY" ]] && yellow "   HINT: Use -p http://127.0.0.1:PORT if behind firewall"
        echo "FAIL:fetch|$username|$url"
        return 0
    fi
    local size_kb=$(awk -v sz="$(wc -c < "$html_file")" 'BEGIN {printf "%.0f", sz/1024}')
    echo " OK (${size_kb} KB)"

    # 2. Extract article via JXA → output file
    local extract_out=$(mktemp) extract_err=$(mktemp)
    if ! osascript -l JavaScript "$JXA_HELPER" -- extract "$html_file" "$extract_out" 2>"$extract_err"; then
        rm -f "$html_file" "$extract_out"
        local errmsg=$(cat "$extract_err" 2>/dev/null || echo "unknown error")
        red "   ERROR: Page structure may have changed"
        echo "   [JXA] $errmsg" >&2
        rm -f "$extract_err"
        echo "FAIL:parse|$username|$url"
        return 0
    fi
    rm -f "$html_file" "$extract_err"
    local article_json=$(cat "$extract_out")
    rm -f "$extract_out"

    if [[ -z "$article_json" ]]; then
        red "   ERROR: JXA returned empty result"
        echo "FAIL:parse|$username|$url"
        return 0
    fi

    # 3. Extract fields → file
    local fields_file=$(mktemp)
    osascript -l JavaScript "$JXA_HELPER" -- fields "$(echo "$article_json" | tee /dev/stderr > "$extract_out" && echo "$extract_out")" "$fields_file" 2>/dev/null
    # Actually write article_json to a temp file properly:
    local art_file=$(mktemp)
    echo "$article_json" > "$art_file"
    osascript -l JavaScript "$JXA_HELPER" -- fields "$art_file" "$fields_file" 2>/dev/null || true
    source "$fields_file" 2>/dev/null || true
    rm -f "$art_file" "$fields_file"

    echo "   Title: ${MGTITLE:-?}"
    echo "   Type : ${MGCLASS:-?}"

    if [[ "${MGCOUNT:-0}" -eq 0 ]]; then
        echo "   No images (type: ${MGCLASS:-Unknown})"
        echo "OK:0|$username|$article_id"
        return 0
    fi
    echo "   Images: $MGCOUNT"

    # 4. Extract images array
    local images_json pick1_out=$(mktemp)
    echo "$article_json" | osascript -l JavaScript "$JXA_HELPER" -- pick images "$pick1_out" 2>/dev/null || true
    images_json=$(cat "$pick1_out" 2>/dev/null || echo "")
    rm -f "$pick1_out"

    # 5. Create output dir
    local safe_username=$(safe_folder_name "$username")
    local safe_id=$(safe_folder_name "$article_id")
    local folder_name="${safe_username}_${safe_id}"
    local post_dir="$output_root/$folder_name"
    mkdir -p "$post_dir"

    # 6. Write meta.json
    local downloaded_at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    local proxy_val="${PROXY:-direct}"
    local imgs_file=$(mktemp)
    echo "$images_json" > "$imgs_file"
    export META_URL="$url" META_USERNAME="$username" META_ARTICLE_ID="$article_id"
    export META_TITLE="$MGTITLE" META_AUTHOR="$MGAUTHOR" META_ARTICLE_CLASS="$MGCLASS"
    export META_DOWNLOADED_AT="$downloaded_at" META_PROXY="$proxy_val" META_DEST="$post_dir/meta.json"
    osascript -l JavaScript "$JXA_HELPER" -- meta "$imgs_file" 2>/dev/null || true
    rm -f "$imgs_file"

    # 7. Download images
    echo "   Downloading $MGCOUNT images..."
    local downloaded=0 failed=0 idx

    # 存一份 images_json 到文件方便诊断
    echo "$images_json" > /tmp/debug_images.json

    for ((idx=0; idx<MGCOUNT; idx++)); do
        local img_out=$(mktemp)
        echo "$images_json" | osascript -l JavaScript "$JXA_HELPER" -- pick "[$idx]" "$img_out" 2>/tmp/debug_pick_err || true
        local img_json=$(cat "$img_out" 2>/dev/null || echo "")
        [[ $idx -eq 0 ]] && echo "   [DIAG] pick[$idx] err=$(cat /tmp/debug_pick_err 2>/dev/null) json_len=${#img_json}" >&2
        rm -f "$img_out"

        local w_out=$(mktemp) h_out=$(mktemp) u_out=$(mktemp) a_out=$(mktemp)
        echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick width "$w_out" 2>/dev/null || true
        echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick height "$h_out" 2>/dev/null || true
        echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick url "$u_out" 2>/dev/null || true
        echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick altUrls "$a_out" 2>/dev/null || true
        local i_width=$(cat "$w_out" 2>/dev/null || echo 0)
        local i_height=$(cat "$h_out" 2>/dev/null || echo 0)
        local i_url=$(cat "$u_out" 2>/dev/null || echo "")
        local i_alt_urls=$(cat "$a_out" 2>/dev/null | tr -d '[]"' | tr ',' '\n')
        rm -f "$w_out" "$h_out" "$u_out" "$a_out"

        local filename=$(printf "%02d_%dx%d.webp" $((idx + 1)) "$i_width" "$i_height")
        local dest_path="$post_dir/$filename"
        local display_idx=$((idx + 1))

        if [[ -f "$dest_path" ]] && [[ $(wc -c < "$dest_path" 2>/dev/null || echo 0) -gt 0 ]]; then
            echo "   SKIP [$display_idx/$MGCOUNT] $filename (exists)"
            downloaded=$((downloaded + 1))
            continue
        fi

        # Build candidates
        local candidates=()
        candidates+=("$i_url")
        [[ "$i_url" =~ tiktokcdn\.com ]] && candidates+=("$(echo "$i_url" | sed 's/p16-lemon8-\(sign\|cross-sign\)-sg\.tiktokcdn\.com/p16-sign-sg.lemon8cdn.com/')")
        while IFS= read -r alt_url; do
            [[ -z "$alt_url" ]] && continue
            candidates+=("$alt_url")
            if [[ "$alt_url" =~ tiktokcdn\.com ]]; then
                local altd=$(echo "$alt_url" | sed 's/p16-lemon8-\(sign\|cross-sign\)-sg\.tiktokcdn\.com/p16-sign-sg.lemon8cdn.com/')
                [[ "$altd" != "$alt_url" ]] && candidates+=("$altd")
            fi
        done <<< "$i_alt_urls"

        # Dedup
        local unique=() seen=""
        for c in "${candidates[@]}"; do
            if [[ ! " $seen " == *" $c "* ]]; then
                seen="$seen $c"
                unique+=("$c")
            fi
        done

        if [[ ${#unique[@]} -eq 0 ]]; then
            red "   FAIL [$display_idx/$MGCOUNT] $filename (no URLs)"
            failed=$((failed + 1))
            continue
        fi

        local success=0 first_url="${unique[0]}"
        [[ $idx -eq 0 ]] && echo "   [DIAG] first URL=$first_url candidates=${#unique[@]}" >&2
        for candidate in "${unique[@]}"; do
            local msg="   DOWNLOAD [$display_idx/$MGCOUNT] $filename"
            [[ "$candidate" != "$first_url" ]] && msg="$msg (alt)"
            printf "%s ... " "$msg"
            if curl_download "$candidate" "$dest_path"; then
                [[ $idx -eq 0 ]] && echo "   [DIAG] curl OK" >&2
                local fsize=$(($(wc -c < "$dest_path" 2>/dev/null || echo 0) / 1024))
                local magic=$(head -c 4 "$dest_path" 2>/dev/null)
                if [[ "$magic" == "RIFF" ]]; then
                    echo "OK (${fsize} KB)"
                    downloaded=$((downloaded + 1))
                    success=1
                    break
                else
                    rm -f "$dest_path"
                    echo "BAD (not WebP)"
                fi
            else
                echo ""
            fi
        done

        if [[ $success -eq 0 ]]; then
            red "   FAIL [$display_idx/$MGCOUNT] $filename"
            failed=$((failed + 1))
        fi
    done

    echo "   DONE: $downloaded ok, $failed failed -> $post_dir"
    echo "OK:$downloaded|$username|$article_id|$post_dir|$failed"
}

# ==================== Main ====================

main() {
    local urls=()
    if [[ -n "$SINGLE_URL" ]]; then
        urls=("$SINGLE_URL")
    else
        [[ ! -f "$URL_FILE" ]] && { red "ERROR: File not found: $URL_FILE"; exit 1; }
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue
            urls+=("$line")
        done < "$URL_FILE"
    fi

    if [[ ${#urls[@]} -eq 0 ]]; then
        yellow "WARN: No URLs to process."; exit 0
    fi

    local output_abs
    output_abs="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"
    [[ "$output_abs" == "//"* ]] && output_abs="$(pwd)/$OUTPUT_DIR"
    echo "Output : $output_abs"
    echo "Proxy  : ${PROXY:-direct (no proxy)}"
    echo "URLs   : ${#urls[@]}"
    echo ""

    local ok_count=0 fail_count=0 total_images=0 failed_details=()

    for url in "${urls[@]}"; do
        local result_line=$(process_post "$url" "$OUTPUT_DIR" | tail -1)
        case "$result_line" in
            OK:*)
                ok_count=$((ok_count + 1))
                total_images=$((total_images + $(echo "$result_line" | cut -d'|' -f1 | cut -d':' -f2)))
                ;;
            FAIL:*)
                fail_count=$((fail_count + 1))
                failed_details+=("$result_line")
                ;;
        esac
    done

    echo ""
    printf "=%.0s" {1..55}
    echo ""
    echo "SUMMARY"
    echo "   Success : $ok_count posts"
    echo "   Failed  : $fail_count posts"
    echo "   Images  : $total_images"
    echo "   Output  : $output_abs"

    if [[ $fail_count -gt 0 ]]; then
        echo ""
        red "Failed posts:"
        for detail in "${failed_details[@]}"; do
            local errtype=$(echo "$detail" | cut -d'|' -f1)
            local username=$(echo "$detail" | cut -d'|' -f2)
            red "   - $username: $errtype"
        done
    fi

    [[ -z "$PROXY" && $fail_count -gt 0 ]] && { echo ""; yellow "HINT: CDN may be blocked. Use proxy:"; yellow "  bash download.sh -p http://127.0.0.1:7897"; }
}

main

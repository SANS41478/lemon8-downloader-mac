#!/bin/bash
# 🍋 Lemon8 Batch Image Downloader (macOS / Linux)
# 真正零依赖 — 只用系统自带的 curl + osascript (JavaScript)
#
# Usage:
#   bash download.sh
#   bash download.sh -f urls.txt -o images -p http://127.0.0.1:7897
#   bash download.sh "https://www.lemon8-app.com/@user/123?region=th" -p http://127.0.0.1:7897
#
# Double-click: rename to download.command (makes it Finder-launchable)

set -euo pipefail

# ==================== Defaults ====================
URL_FILE="urls.txt"
OUTPUT_DIR="images"
PROXY=""
SINGLE_URL=""

# ==================== Parse Args ====================
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
  bash download.sh "https://www.lemon8-app.com/@user/123?region=th" -p http://127.0.0.1:7897

Options:
  -f, --file    URL list file (one per line, # for comments)
  -o, --output  Output directory (default: images)
  -p, --proxy   HTTP proxy, e.g. http://127.0.0.1:7897
  -h, --help    Show this help
EOF
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            SINGLE_URL="$1"
            shift
            ;;
    esac
done

# ==================== Prerequisites ====================
if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required but not found." >&2
    exit 1
fi

if ! command -v osascript &>/dev/null; then
    echo "ERROR: osascript is required but not found." >&2
    echo "       This script requires macOS." >&2
    exit 1
fi

# ==================== Color helpers ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

red()    { echo -e "${RED}$*${NC}"; }
green()  { echo -e "${GREEN}$*${NC}"; }
yellow() { echo -e "${YELLOW}$*${NC}"; }

# ==================== Curl helpers ====================
CURL_OPTS=(-s -L --max-time 60 --connect-timeout 15
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")

# 自动补全 http:// 前缀
if [[ -n "$PROXY" ]]; then
    case "$PROXY" in
        http://*|https://*|socks4://*|socks5://*) ;;
        *) PROXY="http://$PROXY" ;;
    esac
    CURL_OPTS+=(-x "$PROXY")
fi

curl_page_to_file() {
    local url="$1"
    local dest="$2"
    curl "${CURL_OPTS[@]}" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9,th;q=0.8,zh;q=0.7" \
        --max-time 30 \
        -o "$dest" \
        "$url"
}

curl_download() {
    local url="$1"
    local dest="$2"
    local retries=3

    for ((i=retries; i>=0; i--)); do
        if curl "${CURL_OPTS[@]}" \
            -H "Referer: https://www.lemon8-app.com/" \
            -H "Accept: image/webp,image/*,*/*;q=0.8" \
            --max-time 120 \
            -o "$dest" \
            "$url" 2>/dev/null; then
            if [[ -f "$dest" ]]; then
                local sz
                sz=$(wc -c < "$dest" 2>/dev/null || echo 0)
                if [[ "$sz" -gt 0 ]]; then
                    return 0
                fi
            fi
        fi
        rm -f "$dest"
        if (( i > 0 )); then
            printf " (retry %d...)" "$i"
            sleep 2
        fi
    done
    return 1
}

# ==================== JXA (JavaScript for Automation) ====================
# macOS 自带 osascript + JavaScript 引擎，直接替代 python3
# 零依赖：所有 JSON 解析 / URL 解码 / 文件读写都走这里

# 启动时写一个 JXA 脚本到临时文件，后续反复调用
JXA_HELPER=$(mktemp)
cat > "$JXA_HELPER" << 'JXAEOF'
ObjC.import('Foundation');

// --- 工具函数 ---

function readFile(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(
        $(path), $.NSUTF8StringEncoding, null
    );
    if (!s || !s.js) throw new Error('Cannot read: ' + path);
    return s.js;
}

function writeFile(path, content) {
    $.NSString.stringWithString($(content))
        .writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null);
}

function stdout(s) {
    var h = $.NSFileHandle.fileHandleWithStandardOutput;
    h.writeData($(String(s)).dataUsingEncoding($.NSUTF8StringEncoding));
}

function stderr(s) {
    var h = $.NSFileHandle.fileHandleWithStandardError;
    h.writeData($(String(s) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}

function die(msg) {
    stderr('ERROR:' + msg);
    $.NSApplication.sharedApplication.terminate(1);
}

// --- 图片 URL 工具 ---

function makeHiRes(url) {
    // 替换水印模板 → 高清原图
    return url.replace(/~tplv-[^./]+/, '~tplv-sdweummd6v-origin');
}

function genAltCdn(url) {
    // 生成备用 CDN 域名
    var urls = [url];
    if (url.indexOf('tiktokcdn.com') !== -1) {
        var alt = url.replace(
            /p16-lemon8-(sign|cross-sign)-sg\.tiktokcdn\.com/,
            'p16-sign-sg.lemon8cdn.com'
        );
        if (alt !== url) urls.push(alt);
    }
    return urls;
}

function dedup(arr) {
    var seen = {};
    return arr.filter(function(x) { return x && !(x in seen) ? (seen[x] = true) : false; });
}

// --- 主导出：模式 'extract' 或 'fields' 或 'meta' ---

function doExtract(htmlPath) {
    var html = readFile(htmlPath);

    // 找 __remixContext
    var re = /<script\s+type="application\/json"\s+data-ttark="__remixContext"[^>]*>([\s\S]*?)<\/script>/;
    var m = html.match(re);
    if (!m) {
        re = /data-ttark="__remixContext"[^>]*>\s*([\s\S]*?)\s*<\/script>/;
        m = html.match(re);
    }
    if (!m) die('Cannot find __remixContext');

    var encoded = m[1].trim();
    var decoded = decodeURIComponent(encoded);
    var data = JSON.parse(decoded);

    var ld = (data.state || {}).loaderData || {};
    if (Object.keys(ld).length === 0) die('No loaderData in page state');

    var article = null;

    // 策略 1: 找 user_link_name 路由 → ArticleDetail
    for (var k in ld) {
        if (k.indexOf('user_link_name') !== -1 && typeof ld[k] === 'object') {
            var route = ld[k];
            for (var ak in route) {
                if (typeof route[ak] === 'object' &&
                    (route[ak].imageList || route[ak].articleClass || route[ak].largeImage)) {
                    article = route[ak];
                    break;
                }
            }
            if (!article && (route.imageList || route.articleClass)) article = route;
            break;
        }
    }

    // 策略 2: 遍历所有 key 找 imageList
    if (!article) {
        for (var k in ld) {
            if (typeof ld[k] !== 'object') continue;
            var v = ld[k];
            for (var ak in v) {
                if (typeof v[ak] === 'object' && (v[ak].imageList || v[ak].largeImage)) {
                    article = v[ak];
                    break;
                }
            }
            if (article) break;
        }
    }

    // 策略 3: loaderData 本身的 value 就是 article
    if (!article) {
        for (var k in ld) {
            if (typeof ld[k] === 'object' && (ld[k].imageList || ld[k].largeImage)) {
                article = ld[k];
                break;
            }
        }
    }

    // 检测 unavailable 状态
    if (!article) {
        for (var k in ld) {
            var v = ld[k];
            if (typeof v === 'object') {
                for (var ak in v) {
                    if (typeof v[ak] === 'object' && v[ak].unavailableReason) {
                        die('Article unavailable (reason: ' + v[ak].unavailableReason + ')');
                    }
                }
            }
        }
        var keys = Object.keys(ld).map(function(k) {
            var v = ld[k];
            return typeof v === 'object' ? k + '->' + Object.keys(v).slice(0,5).join(',') : k;
        });
        die('Cannot find article. Keys: ' + keys.join('; '));
    }

    var title = String(article.title || 'untitled');
    var author = 'unknown';
    if (article.author && typeof article.author === 'object') {
        author = String(article.author.nickName || article.author.nickname || 'unknown');
    }
    var articleClass = String(article.articleClass || 'Unknown');
    var imageList = article.imageList || [];
    var largeImage = article.largeImage || null;

    // 构建下载列表
    var images = [];
    var idx = 0;

    if (articleClass === 'Gallery' && imageList.length > 0) {
        imageList.forEach(function(img) {
            var url = img.url || '';
            var hiUrl = makeHiRes(url);
            // 原图优先，高清 + CDN 作为 fallback
            var primary = url;
            var fallbacks = [];
            if (hiUrl && hiUrl !== url) fallbacks = fallbacks.concat(genAltCdn(hiUrl));
            genAltCdn(url).forEach(function(u) {
                if (u !== primary && fallbacks.indexOf(u) === -1) fallbacks.push(u);
            });
            fallbacks = dedup(fallbacks);
            images.push({
                index: idx,
                url: primary,
                altUrls: fallbacks,
                width: img.width || 0,
                height: img.height || 0,
                type: 'gallery'
            });
            idx++;
        });
    } else if (articleClass === 'Video' && largeImage) {
        var url = largeImage.url || '';
        var hiUrl = makeHiRes(url);
        var primary = url;
        var fallbacks = [];
        if (hiUrl && hiUrl !== url) fallbacks = fallbacks.concat(genAltCdn(hiUrl));
        genAltCdn(url).forEach(function(u) {
            if (u !== primary && fallbacks.indexOf(u) === -1) fallbacks.push(u);
        });
        fallbacks = dedup(fallbacks);
        images.push({
            index: 0,
            url: primary,
            altUrls: fallbacks,
            width: largeImage.width || 0,
            height: largeImage.height || 0,
            type: 'video_cover'
        });
    }

    var result = {
        title: title,
        author: author,
        articleClass: articleClass,
        imageCount: images.length,
        images: images
    };
    stdout(JSON.stringify(result));
}

function doFields(articleJsonPath) {
    // 从 article JSON 文件提取基本字段，输出 bash 可 eval 的格式
    var json = JSON.parse(readFile(articleJsonPath));
    stdout('MGTITLE=' + JSON.stringify(String(json.title || 'untitled')) + '\n');
    stdout('MGAUTHOR=' + JSON.stringify(String(json.author || 'unknown')) + '\n');
    stdout('MGCLASS=' + JSON.stringify(String(json.articleClass || 'Unknown')) + '\n');
    stdout('MGCOUNT=' + json.imageCount + '\n');
}

function doMeta(imagesJsonPath) {
    // 读取 images JSON，加上环境变量，写出 meta.json
    var images = JSON.parse(readFile(imagesJsonPath));
    var meta = {
        url:           $.NSProcessInfo.processInfo.environment.objectForKey('META_URL').js || '',
        username:      $.NSProcessInfo.processInfo.environment.objectForKey('META_USERNAME').js || '',
        articleId:     $.NSProcessInfo.processInfo.environment.objectForKey('META_ARTICLE_ID').js || '',
        title:         $.NSProcessInfo.processInfo.environment.objectForKey('META_TITLE').js || '',
        author:        $.NSProcessInfo.processInfo.environment.objectForKey('META_AUTHOR').js || '',
        articleClass:  $.NSProcessInfo.processInfo.environment.objectForKey('META_ARTICLE_CLASS').js || '',
        imageCount:    images.length,
        downloadedAt:  $.NSProcessInfo.processInfo.environment.objectForKey('META_DOWNLOADED_AT').js || '',
        proxy:         $.NSProcessInfo.processInfo.environment.objectForKey('META_PROXY').js || 'direct',
        images:        images.map(function(img, i) {
            return {
                index: img.index,
                width: img.width,
                height: img.height,
                url: img.url,
                filename: pad(i+1, 2) + '_' + img.width + 'x' + img.height + '.webp'
            };
        })
    };
    var dest = $.NSProcessInfo.processInfo.environment.objectForKey('META_DEST').js || 'meta.json';
    writeFile(dest, JSON.stringify(meta, null, 2));
}

function doPick(field) {
    // 从 stdin 读 JSON，输出指定字段
    // 对象/数组 → JSON string；基本类型 → 原始值
    var d = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile();
    var s = $.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding).js;
    if (!s) die('No input');
    var obj = JSON.parse(s);

    // 处理 [N] 直接访问数组元素
    var arrRoot = field.match(/^\[(\d+)\]$/);
    if (arrRoot) {
        stdout(JSON.stringify(obj[parseInt(arrRoot[1])]));
        return;
    }

    var val = field.split('.').reduce(function(o, k) {
        var arrMatch = k.match(/^(.+)\[(\d+)\]$/);
        if (arrMatch) {
            var arr = (o || {})[arrMatch[1]];
            return arr ? arr[parseInt(arrMatch[2])] : null;
        }
        return (o || {})[k];
    }, obj);

    if (val === undefined || val === null) stdout('');
    else if (typeof val === 'object') stdout(JSON.stringify(val));
    else stdout(String(val));
}

function pad(n, w) { var s = String(n); while (s.length < w) s = '0' + s; return s; }

// --- 入口 ---
var argv = (typeof arguments !== 'undefined') ? Array.prototype.slice.call(arguments) : [];
// osascript 会把 -e 后面的参数传给脚本，通过 app 的 argv 获取
// 备用: 从 NSProcessInfo 拿
if (argv.length === 0) {
    var rawArgs = $.NSProcessInfo.processInfo.arguments;
    argv = [];
    for (var i = 0; i < rawArgs.count; i++) {
        argv.push(rawArgs.objectAtIndex(i).js);
    }
    // 去掉 osascript 自身的参数: osascript -l JavaScript script.scpt -- mode args...
    // 实际格式: [osascript, -l, JavaScript, scriptPath, --, mode, arg1, ...]
    var dashIdx = argv.indexOf('--');
    if (dashIdx !== -1) argv = argv.slice(dashIdx + 1);
}

var mode = argv[0] || 'extract';

try {
    if (mode === 'extract') {
        doExtract(argv[1]);
    } else if (mode === 'fields') {
        doFields(argv[1]);
    } else if (mode === 'meta') {
        doMeta(argv[1]);
    } else if (mode === 'pick') {
        doPick(argv[1]);
    } else {
        die('Unknown mode: ' + mode);
    }
} catch (e) {
    die(e.message || String(e));
}
JXAEOF

# 清理函数：脚本退出时删除 JXA 临时文件
cleanup() { rm -f "$JXA_HELPER"; }
trap cleanup EXIT

# ==================== Helpers ====================

safe_folder_name() {
    local name="$1"
    echo "$name" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//' | head -c 80
}

parse_url() {
    local url="$1"
    if [[ "$url" =~ lemon8-app\.com/@([^/]+)/([0-9]+) ]]; then
        local username="${BASH_REMATCH[1]}"
        local article_id="${BASH_REMATCH[2]}"
        local region="th"
        [[ "$url" =~ region=([a-z]+) ]] && region="${BASH_REMATCH[1]}"
        echo "$username|$article_id|$region|$url"
    else
        return 1
    fi
}

# ==================== Post Processor ====================

process_post() {
    local url="$1"
    local output_root="$2"

    echo ""
    printf "=%.0s" {1..55}
    echo ""

    # Parse URL
    local parsed
    if ! parsed=$(parse_url "$url"); then
        red "   ERROR: Cannot parse URL: $url"
        echo "FAIL:parse|unknown|$url"
        return 0
    fi

    IFS='|' read -r username article_id region original_url <<< "$parsed"

    echo "[$username] $article_id"
    echo "   URL: $url"

    # 1. Fetch page to temp file
    printf "   Fetching page..."
    local html_file
    html_file=$(mktemp)
    if ! curl_page_to_file "$url" "$html_file" || [[ ! -s "$html_file" ]]; then
        rm -f "$html_file"
        red " ERROR: Failed to fetch page"
        [[ -z "$PROXY" ]] && yellow "   HINT: Use -p http://127.0.0.1:PORT if behind firewall"
        echo "FAIL:fetch|$username|$url"
        return 0
    fi
    local size_kb
    size_kb=$(awk -v sz="$(wc -c < "$html_file")" 'BEGIN {printf "%.0f", sz/1024}')
    echo " OK (${size_kb} KB)"

    # 2. 用 osascript JavaScript 提取文章数据
    local article_json
    if ! article_json=$(osascript -l JavaScript "$JXA_HELPER" -- extract "$html_file" 2>&1); then
        rm -f "$html_file"
        red "   ERROR: Page structure may have changed"
        echo "   $article_json" | grep -q "ERROR:" && echo "   $article_json" >&2
        echo "FAIL:parse|$username|$url"
        return 0
    fi
    rm -f "$html_file"

    # 3. 提取字段 → 写入临时文件后用 JXA fields 模式解析
    local article_file
    article_file=$(mktemp)
    echo "$article_json" > "$article_file"
    eval "$(osascript -l JavaScript "$JXA_HELPER" -- fields "$article_file" 2>/dev/null)"
    rm -f "$article_file"

    echo "   Title: $MGTITLE"
    echo "   Type : $MGCLASS"

    if [[ "$MGCOUNT" -eq 0 ]]; then
        echo "   No images (type: $MGCLASS)"
        echo "OK:0|$username|$article_id"
        return 0
    fi

    echo "   Images: $MGCOUNT"

    # 4. 提取 images JSON 数组
    local images_json
    images_json=$(echo "$article_json" | osascript -l JavaScript "$JXA_HELPER" -- pick images 2>/dev/null)

    # 5. 创建输出目录
    local folder_name safe_username safe_id post_dir
    safe_username=$(safe_folder_name "$username")
    safe_id=$(safe_folder_name "$article_id")
    folder_name="${safe_username}_${safe_id}"
    post_dir="$output_root/$folder_name"
    mkdir -p "$post_dir"

    # 6. 写 meta.json
    local downloaded_at proxy_val
    downloaded_at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    proxy_val="${PROXY:-direct}"

    local images_file
    images_file=$(mktemp)
    echo "$images_json" > "$images_file"

    export META_URL="$url"
    export META_USERNAME="$username"
    export META_ARTICLE_ID="$article_id"
    export META_TITLE="$MGTITLE"
    export META_AUTHOR="$MGAUTHOR"
    export META_ARTICLE_CLASS="$MGCLASS"
    export META_DOWNLOADED_AT="$downloaded_at"
    export META_PROXY="$proxy_val"
    export META_DEST="$post_dir/meta.json"

    osascript -l JavaScript "$JXA_HELPER" -- meta "$images_file" 2>/dev/null
    rm -f "$images_file"

    # 7. 下载图片
    echo "   Downloading $MGCOUNT images..."

    local downloaded=0 failed=0

    for ((idx=0; idx<MGCOUNT; idx++)); do
        local img_json
        img_json=$(echo "$images_json" | osascript -l JavaScript "$JXA_HELPER" -- pick "[$idx]" 2>/dev/null)

        local i_width i_height i_url i_alt_urls
        i_width=$(echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick width 2>/dev/null)
        i_height=$(echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick height 2>/dev/null)
        i_url=$(echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick url 2>/dev/null)
        i_alt_urls=$(echo "$img_json" | osascript -l JavaScript "$JXA_HELPER" -- pick altUrls 2>/dev/null | tr -d '[]"' | tr ',' '\n')

        local filename display_idx dest_path
        filename=$(printf "%02d_%dx%d.webp" $((idx + 1)) "$i_width" "$i_height")
        dest_path="$post_dir/$filename"
        display_idx=$((idx + 1))

        # 跳过已存在且有效的
        if [[ -f "$dest_path" ]]; then
            local existing_size
            existing_size=$(wc -c < "$dest_path" 2>/dev/null || echo 0)
            if [[ "$existing_size" -gt 0 ]]; then
                echo "   SKIP [$display_idx/$MGCOUNT] $filename (exists)"
                downloaded=$((downloaded + 1))
                continue
            fi
        fi

        # 构建候选 URL 列表：主链接 → 备选 → CDN 备用域名
        local candidates=()
        candidates+=("$i_url")
        [[ "$i_url" =~ tiktokcdn\.com ]] && candidates+=("$(echo "$i_url" | sed 's/p16-lemon8-\(sign\|cross-sign\)-sg\.tiktokcdn\.com/p16-sign-sg.lemon8cdn.com/')")
        while IFS= read -r alt_url; do
            [[ -z "$alt_url" ]] && continue
            candidates+=("$alt_url")
            if [[ "$alt_url" =~ tiktokcdn\.com ]]; then
                local altd
                altd=$(echo "$alt_url" | sed 's/p16-lemon8-\(sign\|cross-sign\)-sg\.tiktokcdn\.com/p16-sign-sg.lemon8cdn.com/')
                [[ "$altd" != "$alt_url" ]] && candidates+=("$altd")
            fi
        done <<< "$i_alt_urls"

        # 去重
        local unique_candidates=()
        local seen=""
        for c in "${candidates[@]}"; do
            if [[ ! " $seen " == *" $c "* ]]; then
                seen="$seen $c"
                unique_candidates+=("$c")
            fi
        done

        # 没有可下载的 URL 则跳过
        if [[ ${#unique_candidates[@]} -eq 0 ]]; then
            red "   FAIL [$display_idx/$MGCOUNT] $filename (no URLs)"
            failed=$((failed + 1))
            continue
        fi

        local success=0
        local first_url="${unique_candidates[0]}"
        for candidate in "${unique_candidates[@]}"; do
            local msg="   DOWNLOAD [$display_idx/$MGCOUNT] $filename"
            [[ "$candidate" != "$first_url" ]] && msg="$msg (alt)"
            printf "%s ... " "$msg"
            if curl_download "$candidate" "$dest_path"; then
                local fsize
                fsize=$(wc -c < "$dest_path" 2>/dev/null || echo 0)
                fsize=$((fsize / 1024))
                # 校验 WebP 文件头
                local magic
                magic=$(head -c 4 "$dest_path" 2>/dev/null)
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
        if [[ ! -f "$URL_FILE" ]]; then
            red "ERROR: File not found: $URL_FILE"
            exit 1
        fi
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue
            urls+=("$line")
        done < "$URL_FILE"
    fi

    if [[ ${#urls[@]} -eq 0 ]]; then
        yellow "WARN: No URLs to process."
        exit 0
    fi

    local output_abs
    output_abs="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"
    [[ "$output_abs" == "//"* ]] && output_abs="$(pwd)/$OUTPUT_DIR"
    echo "Output : $output_abs"
    echo "Proxy  : ${PROXY:-direct (no proxy)}"
    echo "URLs   : ${#urls[@]}"
    echo ""

    local ok_count=0 fail_count=0 total_images=0
    local failed_details=()

    for url in "${urls[@]}"; do
        local result_line
        result_line=$(process_post "$url" "$OUTPUT_DIR" | tail -1)

        case "$result_line" in
            OK:*)
                ok_count=$((ok_count + 1))
                local img_cnt
                img_cnt=$(echo "$result_line" | cut -d'|' -f1 | cut -d':' -f2)
                total_images=$((total_images + img_cnt))
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
            local errtype username
            errtype=$(echo "$detail" | cut -d'|' -f1)
            username=$(echo "$detail" | cut -d'|' -f2)
            red "   - $username: $errtype"
        done
    fi

    if [[ -z "$PROXY" && $fail_count -gt 0 ]]; then
        echo ""
        yellow "HINT: CDN may be blocked. Use proxy:"
        yellow "  bash download.sh -p http://127.0.0.1:7897"
    fi
}

main

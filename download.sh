#!/bin/bash
# 🍋 Lemon8 Batch Image Downloader (macOS / Linux)
# Zero dependencies — uses built-in curl and python3
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

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found." >&2
    echo "       Install Xcode Command Line Tools: xcode-select --install" >&2
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
[[ -n "$PROXY" ]] && CURL_OPTS+=(-x "$PROXY")

# Fetch URL, save to a file, return path
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

# Download binary file with retries
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

# ==================== Core Python helper ====================
# This single python3 script does ALL data processing:
#   mode=extract : reads HTML from stdin, outputs article JSON
#   mode=meta    : reads image-list JSON from stdin, writes meta.json

PYTHON_EXTRACT=$(cat << 'PYEOF'
import json, sys, re, os
from urllib.parse import unquote

def extract_article():
    """Read HTML from stdin, extract article data, output JSON to stdout."""
    raw = sys.stdin.read()

    # Find __remixContext script tag content
    m = re.search(
        r'<script\s+type="application/json"\s+data-ttark="__remixContext"[^>]*>(.*?)</script>',
        raw, re.DOTALL
    )
    if not m:
        # Try alternate: the data might be in a different script tag format
        m = re.search(
            r'data-ttark="__remixContext"[^>]*>\s*(.*?)\s*</script>',
            raw, re.DOTALL
        )
    if not m:
        sys.stderr.write("ERROR:Cannot find __remixContext\n")
        sys.exit(1)

    encoded = m.group(1).strip()
    # URL-decode (the JSON is percent-encoded, not HTML-encoded)
    decoded = unquote(encoded)
    data = json.loads(decoded)

    # Navigate: state.loaderData -> route key -> ArticleDetail
    ld = data.get('state', {}).get('loaderData', {})
    if not ld:
        sys.stderr.write("ERROR:No loaderData in page state\n")
        sys.exit(1)

    article = None
    # Strategy 1: find key matching user_link_name / article_id pattern
    for k, v in ld.items():
        if isinstance(v, dict) and ('$user_link_name_' in k or 'user_link_name' in k):
            # Look for $ArticleDetail inside
            for ak, av in v.items():
                if isinstance(av, dict) and ('imageList' in av or 'articleClass' in av or 'largeImage' in av):
                    article = av
                    break
            if not article and ('imageList' in v or 'articleClass' in v):
                article = v
            break

    # Strategy 2: find any value that looks like article data
    if not article:
        for k, v in ld.items():
            if isinstance(v, dict):
                for ak, av in v.items():
                    if isinstance(av, dict) and ('imageList' in av or 'largeImage' in av):
                        article = av
                        break
                if article:
                    break

    # Strategy 3: any direct loaderData value that looks like article data
    if not article:
        for k, v in ld.items():
            if isinstance(v, dict) and ('imageList' in v or 'largeImage' in v):
                article = v
                break

    if not article:
        # Check if the article is intentionally unavailable (region lock, deleted, etc.)
        for k, v in ld.items():
            if isinstance(v, dict):
                for ak, av in v.items():
                    if isinstance(av, dict) and 'unavailableReason' in av:
                        reason = av['unavailableReason']
                        sys.stderr.write(f"ERROR:Article unavailable (reason: {reason})\n")
                        sys.exit(1)
        # Dump available keys for debugging unknown cases
        keys = []
        for k, v in ld.items():
            if isinstance(v, dict):
                keys.append(f"{k}->{list(v.keys())[:5]}")
            else:
                keys.append(f"{k}->{type(v).__name__}")
        sys.stderr.write(f"ERROR:Cannot find article. Keys: {keys}\n")
        sys.exit(1)

    # Build output
    title = str(article.get('title', 'untitled'))
    author = 'unknown'
    aobj = article.get('author')
    if isinstance(aobj, dict):
        author = str(aobj.get('nickName', aobj.get('nickname', 'unknown')))
    article_class = str(article.get('articleClass', 'Unknown'))
    image_list = article.get('imageList', [])
    large_image = article.get('largeImage', None)
    content = str(article.get('content', ''))

    # Build image download list with CDN variants
    images = []
    idx = 0

    def make_hi_res(u, logo_pattern=None):
        """Replace watermark template with origin quality."""
        return re.sub(r'~tplv-[^./]+', '~tplv-sdweummd6v-origin', u)

    def gen_alt_urls(u):
        """Generate original + alternative CDN URLs."""
        urls = [u]
        if 'tiktokcdn.com' in u:
            alt = re.sub(
                r'p16-lemon8-(sign|cross-sign)-sg\.tiktokcdn\.com',
                'p16-sign-sg.lemon8cdn.com', u
            )
            if alt != u:
                urls.append(alt)
        return list(set(urls))

    if article_class == 'Gallery' and image_list:
        for img in image_list:
            url = img.get('url', '')
            hi_url = make_hi_res(url)
            alt_urls = list(set(filter(None,
                gen_alt_urls(url) + gen_alt_urls(hi_url)
            )))
            images.append({
                'index': idx,
                'url': hi_url or url,
                'altUrls': alt_urls,
                'width': img.get('width', 0),
                'height': img.get('height', 0),
                'type': 'gallery'
            })
            idx += 1
    elif article_class == 'Video' and large_image:
        url = large_image.get('url', '')
        hi_url = make_hi_res(url)
        alt_urls = list(set(filter(None,
            gen_alt_urls(url) + gen_alt_urls(hi_url)
        )))
        images.append({
            'index': 0,
            'url': hi_url or url,
            'altUrls': alt_urls,
            'width': large_image.get('width', 0),
            'height': large_image.get('height', 0),
            'type': 'video_cover'
        })

    result = {
        'title': title,
        'author': author,
        'articleClass': article_class,
        'imageCount': len(images),
        'images': images
    }
    print(json.dumps(result, ensure_ascii=False))


def write_meta():
    """Read image-list + metadata from env, write meta.json."""
    image_list_json = sys.stdin.read()
    images = json.loads(image_list_json)

    meta = {
        'url': os.environ.get('META_URL', ''),
        'username': os.environ.get('META_USERNAME', ''),
        'articleId': os.environ.get('META_ARTICLE_ID', ''),
        'title': os.environ.get('META_TITLE', ''),
        'author': os.environ.get('META_AUTHOR', ''),
        'articleClass': os.environ.get('META_ARTICLE_CLASS', ''),
        'imageCount': len(images),
        'downloadedAt': os.environ.get('META_DOWNLOADED_AT', ''),
        'proxy': os.environ.get('META_PROXY', 'direct'),
        'images': [{
            'index': img['index'],
            'width': img['width'],
            'height': img['height'],
            'url': img['url'],
            'filename': f"{img['index']+1:02d}_{img['width']}x{img['height']}.webp"
        } for img in images]
    }

    dest = os.environ.get('META_DEST', 'meta.json')
    with open(dest, 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'extract'
    if mode == 'extract':
        extract_article()
    elif mode == 'meta':
        write_meta()
    else:
        sys.stderr.write(f"ERROR:Unknown mode: {mode}\n")
        sys.exit(1)
PYEOF
)

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

    # 2. Parse data using python3 (reads HTML from file via stdin)
    local article_json
    if ! article_json=$(python3 -c "$PYTHON_EXTRACT" extract < "$html_file" 2>&1); then
        rm -f "$html_file"
        red "   ERROR: Page structure may have changed"
        echo "   $article_json" | grep -q "ERROR:" && echo "   $article_json" >&2
        echo "FAIL:parse|$username|$url"
        return 0
    fi
    rm -f "$html_file"

    # Extract fields from article JSON
    local title author article_class image_count
    title=$(echo "$article_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
    author=$(echo "$article_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['author'])")
    article_class=$(echo "$article_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['articleClass'])")
    image_count=$(echo "$article_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['imageCount'])")

    echo "   Title: $title"
    echo "   Type : $article_class"

    if [[ "$image_count" -eq 0 ]]; then
        echo "   No images (type: $article_class)"
        echo "OK:0|$username|$article_id"
        return 0
    fi

    echo "   Images: $image_count"

    # Extract images JSON
    local images_json
    images_json=$(echo "$article_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['images']))")

    # 3. Create output dir
    local folder_name safe_username safe_id post_dir
    safe_username=$(safe_folder_name "$username")
    safe_id=$(safe_folder_name "$article_id")
    folder_name="${safe_username}_${safe_id}"
    post_dir="$output_root/$folder_name"
    mkdir -p "$post_dir"

    # 4. Save metadata
    local downloaded_at proxy_val
    downloaded_at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    proxy_val="${PROXY:-direct}"

    export META_URL="$url"
    export META_USERNAME="$username"
    export META_ARTICLE_ID="$article_id"
    export META_TITLE="$title"
    export META_AUTHOR="$author"
    export META_ARTICLE_CLASS="$article_class"
    export META_DOWNLOADED_AT="$downloaded_at"
    export META_PROXY="$proxy_val"
    export META_DEST="$post_dir/meta.json"

    echo "$images_json" | python3 -c "$PYTHON_EXTRACT" meta 2>/dev/null

    # 5. Download images
    echo "   Downloading $image_count images..."

    local downloaded=0 failed=0

    for ((idx=0; idx<image_count; idx++)); do
        local img_json
        img_json=$(echo "$images_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[$idx]))")

        local i_width i_height i_alt_urls i_url
        i_width=$(echo "$img_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['width'])")
        i_height=$(echo "$img_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['height'])")
        i_url=$(echo "$img_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")
        i_alt_urls=$(echo "$img_json" | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)['altUrls']))")

        local filename display_idx dest_path
        filename=$(printf "%02d_%dx%d.webp" $((idx + 1)) "$i_width" "$i_height")
        dest_path="$post_dir/$filename"
        display_idx=$((idx + 1))

        # Skip existing
        if [[ -f "$dest_path" ]]; then
            local existing_size
            existing_size=$(wc -c < "$dest_path" 2>/dev/null || echo 0)
            if [[ "$existing_size" -gt 0 ]]; then
                echo "   SKIP [$display_idx/$image_count] $filename (exists)"
                downloaded=$((downloaded + 1))
                continue
            fi
        fi

        # Build candidate URL list (deduplicated)
        local candidates=()
        while IFS= read -r cdn_url; do
            [[ -z "$cdn_url" ]] && continue
            # Also generate alt CDN variants
            candidates+=("$cdn_url")
            if [[ "$cdn_url" =~ tiktokcdn\.com ]]; then
                local alt
                alt=$(echo "$cdn_url" | sed 's/p16-lemon8-\(sign\|cross-sign\)-sg\.tiktokcdn\.com/p16-sign-sg.lemon8cdn.com/')
                if [[ "$alt" != "$cdn_url" ]]; then
                    candidates+=("$alt")
                fi
            fi
        done <<< "$i_alt_urls"

        # Deduplicate while preserving order
        local unique_candidates=()
        local seen=""
        for c in "${candidates[@]}"; do
            if [[ ! " $seen " =~ " $c " ]]; then
                seen="$seen $c"
                unique_candidates+=("$c")
            fi
        done

        local success=0
        for candidate in "${unique_candidates[@]}"; do
            local msg="   DOWNLOAD [$display_idx/$image_count] $filename"
            [[ "$candidate" != "${unique_candidates[0]}" ]] && msg="$msg (alt CDN)"
            printf "%s ... " "$msg"
            if curl_download "$candidate" "$dest_path"; then
                local fsize
                fsize=$(wc -c < "$dest_path" 2>/dev/null || echo 0)
                fsize=$((fsize / 1024))
                echo "OK (${fsize} KB)"
                downloaded=$((downloaded + 1))
                success=1
                break
            else
                echo ""
            fi
        done

        if [[ $success -eq 0 ]]; then
            red "   FAIL [$display_idx/$image_count] $filename"
            failed=$((failed + 1))
        fi
    done

    echo "   DONE: $downloaded ok, $failed failed -> $post_dir"
    echo "OK:$downloaded|$username|$article_id|$post_dir|$failed"
}

# ==================== Main ====================

main() {
    local urls=()

    # Read URLs
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

    # Show config
    local output_abs
    output_abs="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"
    [[ "$output_abs" == "//"* ]] && output_abs="$(pwd)/$OUTPUT_DIR"
    echo "Output : $output_abs"
    echo "Proxy  : ${PROXY:-direct (no proxy)}"
    echo "URLs   : ${#urls[@]}"
    echo ""

    # Process all URLs
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

    # Summary
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

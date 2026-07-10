#!/bin/bash
# 🍋 Lemon8 Downloader — double-click to run in Terminal
#
# To configure:
#   1. Edit this file and change PROXY_PORT to your proxy's HTTP port
#   2. Set USE_PROXY to 1 to enable proxy
#
# First run: right-click → Open (Gatekeeper bypass)

# ==================== CONFIG ====================
USE_PROXY=0               # Set to 1 to enable proxy
PROXY_PORT=7897           # Your proxy HTTP port
URL_FILE="urls.txt"       # File with Lemon8 post URLs
OUTPUT_DIR="images"       # Where to save images
# ===============================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Build proxy arg
PROXY_ARG=""
if [[ "$USE_PROXY" -eq 1 ]]; then
    PROXY_ARG="-p http://127.0.0.1:${PROXY_PORT}"
fi

echo "============================================"
echo "  Lemon8 Batch Image Downloader (macOS)"
if [[ "$USE_PROXY" -eq 1 ]]; then
    echo "  Proxy : 127.0.0.1:${PROXY_PORT}"
else
    echo "  Proxy : direct (no proxy)"
fi
echo "  Output: ${OUTPUT_DIR}"
echo "  URLs  : ${URL_FILE}"
echo "============================================"
echo ""

# Check if urls.txt exists, create from example if needed
if [[ ! -f "$URL_FILE" ]]; then
    if [[ -f "urls.example.txt" ]]; then
        echo "[INIT] First run — creating ${URL_FILE} from example..."
        cp "urls.example.txt" "$URL_FILE"
        echo "[INIT] Please edit ${URL_FILE} to add your Lemon8 post links."
        echo "[INIT] Also check USE_PROXY and PROXY_PORT in $(basename "$0")"
        echo ""
        echo "Press any key to exit..."
        read -r
        exit 0
    fi
fi

# Check if urls.txt has actual links
LINK_COUNT=$(grep -cv '^\s*#' "$URL_FILE" 2>/dev/null || echo 0)
if [[ "$LINK_COUNT" -eq 0 ]]; then
    echo "[WARN] ${URL_FILE} has no links!"
    echo "       Add Lemon8 post URLs to ${URL_FILE} first."
    echo ""
    echo "Press any key to exit..."
    read -r
    exit 0
fi

# Run the main script
bash "$SCRIPT_DIR/download.sh" -f "$URL_FILE" -o "$OUTPUT_DIR" $PROXY_ARG

echo ""
echo "--------------------------------------------"
echo "  Done. Press any key to exit..."
read -r

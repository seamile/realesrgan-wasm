#!/usr/bin/env bash
# Download the default ncnn models into models/.
# Everything in models/ is packed into the WASM .data on the next build.
#
# Usage:
#   ./scripts/download_models.sh
#   ./scripts/download_models.sh --include-wdn
#
# Downloads the four production models: animevideov3-x4, general-x4v3,
# realesrgan-x4plus and realesrgan-x4plus-anime.
#
# realesrgan-x2plus has no official ncnn build; convert it locally with the
# official pipeline: ./scripts/convert_x2plus.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DEST="$ROOT/models"
INCLUDE_WDN=0
PYTHON="${PYTHON:-python3}"

usage() {
    sed -n '2,16p' "$0"
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
}

# Fall back to Python's standard library when unzip is unavailable.
extract_zip() {
    local archive="$1" dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$dest"
    else
        "$PYTHON" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$archive" "$dest"
    fi
}

for arg in "$@"; do
    case "$arg" in
        --include-wdn) INCLUDE_WDN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --retry 3 --retry-delay 2 --output "$2.part" "$1" && mv -f "$2.part" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    download() { wget --quiet --show-progress --output-document="$2.part" "$1" && mv -f "$2.part" "$2"; }
else
    echo "Missing download tool: install curl or wget." >&2
    exit 1
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "Python interpreter not found: $PYTHON" >&2
    echo "Set PYTHON=/path/to/python3 or install Python 3.9+." >&2
    exit 1
fi

download_if_needed() {
    local url="$1" out="$2"
    if [[ -s "$out" ]] && (( $(file_size "$out") > 1000 )); then
        echo "Skip $(basename "$out")"
        return
    fi
    echo "Downloading $(basename "$out") ..."
    rm -f "$out.part"
    download "$url" "$out"
}

base="https://github.com/TransparentLC/realesrgan-gui/releases/download/additional-models"
download_if_needed "$base/realesr-general-x4v3.bin" "$DEST/realesr-general-x4v3.bin"
download_if_needed "$base/realesr-general-x4v3.param" "$DEST/realesr-general-x4v3.param"

if (( INCLUDE_WDN )); then
    download_if_needed "$base/realesr-general-wdn-x4v3.bin" "$DEST/realesr-general-wdn-x4v3.bin"
    download_if_needed "$base/realesr-general-wdn-x4v3.param" "$DEST/realesr-general-wdn-x4v3.param"
fi

# The Ubuntu package contains the official animevideov3 ncnn models.
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/real-esrgan-models.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
zip="$tmp_dir/realesrgan-ncnn-vulkan-20220424-ubuntu.zip"
extract="$tmp_dir/extract"
url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-ubuntu.zip"

echo "Downloading official Ubuntu package for animevideov3 ..."
download "$url" "$zip"
mkdir -p "$extract"
extract_zip "$zip" "$extract"

found=0
while IFS= read -r -d '' model; do
    cp -f "$model" "$DEST/"
    echo "Copied $(basename "$model")"
    found=1
done < <(find "$extract" -type f -name 'realesr-animevideov3-x4.*' -print0)

if (( ! found )); then
    echo "The official package did not contain animevideov3 models." >&2
    exit 1
fi

while IFS= read -r -d '' model; do
    cp -f "$model" "$DEST/"
    echo "Copied $(basename "$model")"
done < <(find "$extract" -type f -name 'realesrgan-x4plus*' -print0)

echo
echo "Done. Models in $DEST"
echo "Note: everything in models/ is packed into the WASM .data on the next build."
echo "Optional wdn variant (CPU): ./scripts/download_models.sh --include-wdn"
echo "Optional x2plus (CPU):      ./scripts/convert_x2plus.sh (needs ncnn host tools)"
echo "Optional WebGPU ONNX:       ./scripts/prepare_webgpu_models.sh"

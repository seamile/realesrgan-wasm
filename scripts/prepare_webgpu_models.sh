#!/usr/bin/env bash
# Prepare ONNX models and onnxruntime-web assets for Route B (WebGPU).
# Usage: ./scripts/prepare_webgpu_models.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WEIGHTS="$ROOT/_convert/weights"
ONNX_DIR="$ROOT/web/models-onnx"
ORT_DIR="$ROOT/web/ort"
PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "Python interpreter not found: $PYTHON" >&2
    echo "Set PYTHON=/path/to/python3 or install Python 3.9+." >&2
    exit 1
fi
for command_name in npm unzip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 1
    fi
done

if command -v curl >/dev/null 2>&1; then
    download() { curl --fail --location --retry 3 --retry-delay 2 --output "$2.part" "$1" && mv -f "$2.part" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    download() { wget --quiet --show-progress --output-document="$2.part" "$1" && mv -f "$2.part" "$2"; }
else
    echo "Missing download tool: install curl or wget." >&2
    exit 1
fi

mkdir -p "$WEIGHTS" "$ONNX_DIR" "$ORT_DIR"

download_if_needed() {
    local url="$1" out="$2"
    if [[ -s "$out" ]] && (( $(stat -c '%s' "$out") > 1000 )); then
        echo "Skip $(basename "$out")"
        return
    fi
    echo "Downloading $(basename "$out") ..."
    rm -f "$out.part"
    download "$url" "$out"
}

release="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0"
download_if_needed "$release/realesr-animevideov3.pth" "$WEIGHTS/realesr-animevideov3.pth"
download_if_needed "$release/realesr-general-x4v3.pth" "$WEIGHTS/realesr-general-x4v3.pth"

x2pth="$ROOT/_convert/RealESRGAN_x2plus.pth"
if [[ ! -f "$x2pth" ]]; then
    download_if_needed "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" "$x2pth"
fi

# Fixed spatial sizes are required by ORT WebGPU buffer reuse.
find "$ONNX_DIR" -maxdepth 1 -type f -name '*.onnx' -delete

export_onnx() {
    local output_name="$1"
    shift
    echo "Exporting $output_name ..."
    "$PYTHON" "$SCRIPT_DIR/pytorch2onnx_webgpu.py" "$@"
}

# tilesize=128, prepadding=10 -> fixed input 148x148
export_onnx realesr-animevideov3-x2.onnx \
    --arch anime-scaled --input "$WEIGHTS/realesr-animevideov3.pth" \
    --output "$ONNX_DIR/realesr-animevideov3-x2.onnx" --scale 2 --size 148
export_onnx realesr-animevideov3-x3.onnx \
    --arch anime-scaled --input "$WEIGHTS/realesr-animevideov3.pth" \
    --output "$ONNX_DIR/realesr-animevideov3-x3.onnx" --scale 3 --size 148
export_onnx realesr-animevideov3-x4.onnx \
    --arch anime-scaled --input "$WEIGHTS/realesr-animevideov3.pth" \
    --output "$ONNX_DIR/realesr-animevideov3-x4.onnx" --scale 4 --size 148
export_onnx realesr-general-x4v3.onnx \
    --arch srvgg --input "$WEIGHTS/realesr-general-x4v3.pth" \
    --output "$ONNX_DIR/realesr-general-x4v3.onnx" --scale 4 --num-conv 32 --size 148

# tilesize=64, prepadding=10 -> 84 (even for pixel_unshuffle)
export_onnx realesrgan-x2plus.onnx \
    --arch rrdb --input "$x2pth" \
    --output "$ONNX_DIR/realesrgan-x2plus.onnx" --scale 2 --num-block 23 --size 84

cat > "$ONNX_DIR/manifest.json" <<'JSON'
{
  "version": 1,
  "backend": "webgpu",
  "models": [
    {"name":"realesr-animevideov3-x2","file":"realesr-animevideov3-x2.onnx","scale":2,"input":"data","output":"output","tilesize":128,"prepadding":10,"align":1},
    {"name":"realesr-animevideov3-x3","file":"realesr-animevideov3-x3.onnx","scale":3,"input":"data","output":"output","tilesize":128,"prepadding":10,"align":1},
    {"name":"realesr-animevideov3-x4","file":"realesr-animevideov3-x4.onnx","scale":4,"input":"data","output":"output","tilesize":128,"prepadding":10,"align":1},
    {"name":"realesr-general-x4v3","file":"realesr-general-x4v3.onnx","scale":4,"input":"data","output":"output","tilesize":128,"prepadding":10,"align":1},
    {"name":"realesrgan-x2plus","file":"realesrgan-x2plus.onnx","scale":2,"input":"data","output":"output","tilesize":64,"prepadding":10,"align":2}
  ]
}
JSON
echo "Wrote web/models-onnx/manifest.json"

# Vendor all ORT files needed by offline/COOP pages.
(
    cd "$ROOT"
    npm install --no-fund --no-audit
)
ort_src="$ROOT/node_modules/onnxruntime-web/dist"
if [[ ! -f "$ort_src/ort.webgpu.min.js" ]]; then
    echo "onnxruntime-web WebGPU bundle not found in $ort_src" >&2
    exit 1
fi
find "$ORT_DIR" -maxdepth 1 -type f -delete
cp -f "$ort_src/ort.webgpu.min.js" "$ORT_DIR/"
[[ ! -f "$ort_src/ort.webgpu.min.js.map" ]] || cp -f "$ort_src/ort.webgpu.min.js.map" "$ORT_DIR/"
shopt -s nullglob
ort_wasm=("$ort_src"/ort-wasm-simd-threaded.*)
if (( ${#ort_wasm[@]} == 0 )); then
    echo "No ort-wasm-simd-threaded.* files found in $ort_src" >&2
    exit 1
fi
cp -f "${ort_wasm[@]}" "$ORT_DIR/"

echo "Copied ORT assets to $ORT_DIR"
echo "Done. ONNX models in $ONNX_DIR, ORT in $ORT_DIR"
#!/usr/bin/env bash
# Official-style conversion: RealESRGAN_x2plus.pth -> clean ncnn model.
#
# Set NCNN_ONNX2NCNN and NCNNOPTIMIZE when the tools are not on PATH, e.g.:
#   NCNN_ONNX2NCNN=/path/to/onnx2ncnn NCNNOPTIMIZE=/path/to/ncnnoptimize \
#     ./scripts/convert_x2plus.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONV="$ROOT/_convert"
PTH="$CONV/RealESRGAN_x2plus.pth"
ONNX="$CONV/realesrgan-x2plus.onnx"
RAW_PARAM="$CONV/realesrgan-x2plus-raw.param"
RAW_BIN="$CONV/realesrgan-x2plus-raw.bin"
OPT_PARAM="$CONV/realesrgan-x2plus.param"
OPT_BIN="$CONV/realesrgan-x2plus.bin"
DEST="$ROOT/models"
PYTHON="${PYTHON:-python3}"

find_tool() {
    local configured="$1" name="$2" candidate
    if [[ -n "$configured" ]]; then
        [[ -x "$configured" ]] || { echo "Tool is not executable: $configured" >&2; exit 1; }
        printf '%s\n' "$configured"
        return
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return
    fi
    for candidate in \
        "$ROOT/_convert/$name" \
        "$ROOT/_convert/ncnn-build/tools/$name" \
        "$ROOT/build-tools/$name"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    echo "Unable to find $name. Install/build it, put it on PATH, or set the corresponding environment variable." >&2
    exit 1
}

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "Python interpreter not found: $PYTHON" >&2
    exit 1
fi
[[ -f "$PTH" ]] || { echo "Missing $PTH" >&2; exit 1; }
mkdir -p "$CONV" "$DEST"

tools_onnx="$(find_tool "${NCNN_ONNX2NCNN:-}" onnx2ncnn)"
tools_opt="$(find_tool "${NCNNOPTIMIZE:-}" ncnnoptimize)"

echo "==> PyTorch -> ONNX"
"$PYTHON" "$SCRIPT_DIR/pytorch2onnx_x2plus.py" --input "$PTH" --output "$ONNX" --scale 2 --size 64

echo "==> ONNX -> ncnn (raw)"
"$tools_onnx" "$ONNX" "$RAW_PARAM" "$RAW_BIN"

echo "==> ncnnoptimize (fp16 flag=1 as official docs)"
"$tools_opt" "$RAW_PARAM" "$RAW_BIN" "$OPT_PARAM" "$OPT_BIN" 1

echo "==> Ensure blob names data/output"
tmp_param="$OPT_PARAM.tmp.$$"
sed -E 's/^(Input[[:space:]]+[^[:space:]]+[[:space:]]+0[[:space:]]+1[[:space:]]+)[^[:space:]]+/\1data/' "$OPT_PARAM" > "$tmp_param"
mv -f "$tmp_param" "$OPT_PARAM"

if ! grep -Eq '(^|[[:space:]])output([[:space:]]|$)' "$OPT_PARAM"; then
    echo "WARNING: no blob named 'output' found; check param manually" >&2
fi

echo "==> Layer type summary"
awk '/^[[:alpha:]]/ { print $1 }' "$OPT_PARAM" | sort | uniq -c | sort -nr | head -20
if grep -Eq '^Shape([[:space:]]|$)' "$OPT_PARAM"; then
    echo "WARNING: Shape layer still present after conversion" >&2
else
    echo "OK: no Shape layer"
fi

cp -f "$OPT_PARAM" "$DEST/realesrgan-x2plus.param"
cp -f "$OPT_BIN" "$DEST/realesrgan-x2plus.bin"
echo "Installed to $DEST"
wc -c "$DEST/realesrgan-x2plus.param" "$DEST/realesrgan-x2plus.bin"
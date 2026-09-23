#!/usr/bin/env bash
# Build the native ncnn host tools used by scripts/convert_x2plus.sh
# (and convert_x4plus.sh if you run it) into _convert/ncnn-build/tools/,
# which is one of the paths those scripts search automatically.
#
#   ncnnoptimize  built from the ncnn submodule
#   onnx2ncnn     upstream stopped building it (ncnn commit a6eda68f,
#                 "disable onnx2ncnn build"), so it is compiled standalone
#                 from ncnn/tools/onnx/onnx2ncnn.cpp with protoc + libprotobuf
#
# Requirements: cmake, a C++17 compiler, protoc + libprotobuf
# (macOS: brew install protobuf; Debian/Ubuntu: apt install protobuf-compiler libprotobuf-dev)
#
# Usage:
#   ./scripts/build_ncnn_tools.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$ROOT/_convert/ncnn-build"
OUT_DIR="$BUILD_DIR/tools"
ONNX_BUILD_DIR="$ROOT/_convert/onnx2ncnn-build"
ONNX_SRC="$ROOT/ncnn/tools/onnx"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

if [[ ! -f "$ROOT/ncnn/CMakeLists.txt" ]]; then
    echo "Missing ncnn submodule. Run: git submodule update --init --recursive" >&2
    exit 1
fi
if [[ ! -f "$ONNX_SRC/onnx2ncnn.cpp" ]]; then
    echo "Missing $ONNX_SRC/onnx2ncnn.cpp" >&2
    exit 1
fi

CXX_BIN="${CXX:-c++}"
for tool in cmake "$CXX_BIN" protoc; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Unable to find $tool. Install it or put it on PATH." >&2
        exit 1
    }
done

if pkg-config --exists protobuf 2>/dev/null; then
    read -r -a PROTOBUF_CFLAGS <<<"$(pkg-config --cflags protobuf)"
    read -r -a PROTOBUF_LIBS <<<"$(pkg-config --libs protobuf)"
elif [[ -d "$(brew --prefix protobuf 2>/dev/null)/include" ]]; then
    PROTOBUF_PREFIX="$(brew --prefix protobuf)"
    PROTOBUF_CFLAGS=("-I$PROTOBUF_PREFIX/include")
    PROTOBUF_LIBS=("-L$PROTOBUF_PREFIX/lib" -lprotobuf)
else
    echo "Unable to locate protobuf headers/libs. Install protobuf or set PKG_CONFIG_PATH." >&2
    exit 1
fi

mkdir -p "$OUT_DIR" "$ONNX_BUILD_DIR"

echo "==> ncnnoptimize (native, from the ncnn submodule)"
cmake -S "$ROOT/ncnn" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DNCNN_BUILD_TOOLS=ON \
    -DNCNN_BUILD_EXAMPLES=OFF \
    -DNCNN_BUILD_BENCHMARK=OFF \
    -DNCNN_VULKAN=OFF \
    -DNCNN_PYTHON=OFF \
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$OUT_DIR"
cmake --build "$BUILD_DIR" --target ncnnoptimize -j "$JOBS"

echo "==> onnx2ncnn (standalone)"
protoc --cpp_out="$ONNX_BUILD_DIR" -I "$ONNX_SRC" "$ONNX_SRC/onnx.proto"
"$CXX_BIN" -std=c++17 -O2 -I "$ONNX_BUILD_DIR" \
    "${PROTOBUF_CFLAGS[@]}" \
    "$ONNX_SRC/onnx2ncnn.cpp" "$ONNX_BUILD_DIR/onnx.pb.cc" \
    "${PROTOBUF_LIBS[@]}" \
    -o "$OUT_DIR/onnx2ncnn"

echo ""
echo "Built:"
echo "  $OUT_DIR/ncnnoptimize"
echo "  $OUT_DIR/onnx2ncnn"
echo "scripts/convert_x2plus.sh finds them there automatically."

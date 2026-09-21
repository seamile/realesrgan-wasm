#!/bin/sh
# Build Real-ESRGAN ncnn WebAssembly (Route A: CPU) and assemble a self-contained dist/ site.
set -e

cd "$(dirname "$0")"

if [ ! -f ./emsdk/emsdk_env.sh ]; then
  echo "Submodule emsdk missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi
PROJECT_ROOT=$(pwd)
cd ./emsdk
EMSDK_QUIET=1
export EMSDK_QUIET
. ./emsdk_env.sh >/dev/null
cd "$PROJECT_ROOT"

if [ ! -f "$EMSDK/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" ]; then
  echo "Emscripten is not installed. Run: cd emsdk && ./emsdk install 3.1.28 && ./emsdk activate 3.1.28" >&2
  exit 1
fi

if [ ! -f ./ncnn/CMakeLists.txt ]; then
  echo "Submodule ncnn missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! ls ./models/*.bin >/dev/null 2>&1; then
  echo "No models in ./models/. Run: ./scripts/download_models.sh" >&2
  exit 1
fi

WEB=./web
BUILD=./build
ONNX_DIR="$WEB/models-onnx"
ORT_DIR="$WEB/ort"
PREPARE_HINT="Run ./scripts/prepare_webgpu_models.sh before building."

require_file() {
  if [ ! -s "$1" ]; then
    echo "Missing publish asset: $1" >&2
    echo "$2" >&2
    exit 1
  fi
}

# Validate every publish input up front so a failed build never replaces a good dist/.
require_file "$WEB/index.html" "Repository is incomplete: web/index.html is missing."
require_file "$WEB/wasmFeatureDetect.js" "Repository is incomplete: web/wasmFeatureDetect.js is missing."
require_file "$WEB/webgpu/realesrgan-webgpu.js" "Repository is incomplete: web/webgpu/realesrgan-webgpu.js is missing."
require_file "$ORT_DIR/ort.webgpu.min.js" "$PREPARE_HINT"
require_file "$ORT_DIR/ort-wasm-simd-threaded.asyncify.mjs" "$PREPARE_HINT"
require_file "$ORT_DIR/ort-wasm-simd-threaded.asyncify.wasm" "$PREPARE_HINT"
require_file "$ONNX_DIR/manifest.json" "$PREPARE_HINT"

manifest_models=$(sed -n 's/.*"file"[[:space:]]*:[[:space:]]*"\([^"]*\.onnx\)".*/\1/p' "$ONNX_DIR/manifest.json")
if [ -z "$manifest_models" ]; then
  echo "No ONNX model entries in $ONNX_DIR/manifest.json." >&2
  echo "$PREPARE_HINT" >&2
  exit 1
fi
for model in $manifest_models; do
  require_file "$ONNX_DIR/$model" "$PREPARE_HINT"
done

mkdir -p "$BUILD"
(
  cd "$BUILD"
  cmake \
    -DCMAKE_TOOLCHAIN_FILE="$EMSDK/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake" \
    -DWASM_FEATURE=simd-threads \
    -DNCNN_THREADS=ON \
    -DNCNN_OPENMP=ON \
    -DNCNN_SIMPLEOMP=ON \
    -DNCNN_RUNTIME_CPU=OFF \
    -DNCNN_SSE2=ON \
    -DNCNN_AVX2=OFF \
    -DNCNN_AVX=OFF \
    -DNCNN_VULKAN=OFF \
    -DNCNN_BUILD_TOOLS=OFF \
    -DNCNN_BUILD_EXAMPLES=OFF \
    -DNCNN_BUILD_BENCHMARK=OFF \
    ..
  cmake --build . -j4
)

TMP_DIST="./.dist.tmp.$$"
trap 'rm -rf "$TMP_DIST"' EXIT INT TERM
rm -rf "$TMP_DIST"
mkdir -p "$TMP_DIST/statics/webgpu" "$TMP_DIST/statics/ort" "$TMP_DIST/models"

cp -f "$WEB/index.html" "$TMP_DIST/index.html"
cp -f "$WEB/wasmFeatureDetect.js" "$TMP_DIST/statics/"
cp -f "$WEB/webgpu/realesrgan-webgpu.js" "$TMP_DIST/statics/webgpu/"

cp -f "$ORT_DIR"/* "$TMP_DIST/statics/ort/"

ARTIFACT=real-esrgan-ncnn-webassembly-simd-threads
for asset in "$ARTIFACT.js" "$ARTIFACT.wasm" "$ARTIFACT.worker.js" "$ARTIFACT.data"; do
  require_file "$BUILD/$asset" "Emscripten build did not produce $asset."
done
cp -f "$BUILD/$ARTIFACT.js" "$TMP_DIST/statics/"
cp -f "$BUILD/$ARTIFACT.wasm" "$TMP_DIST/statics/"
cp -f "$BUILD/$ARTIFACT.worker.js" "$TMP_DIST/statics/"
cp -f "$BUILD/$ARTIFACT.data" "$TMP_DIST/models/"

cp -f "$ONNX_DIR/manifest.json" "$TMP_DIST/models/"
cp -f "$ONNX_DIR"/*.onnx "$TMP_DIST/models/"

for asset in \
  index.html \
  statics/wasmFeatureDetect.js \
  statics/webgpu/realesrgan-webgpu.js \
  statics/ort/ort.webgpu.min.js \
  statics/ort/ort-wasm-simd-threaded.asyncify.wasm \
  statics/real-esrgan-ncnn-webassembly-simd-threads.js \
  statics/real-esrgan-ncnn-webassembly-simd-threads.wasm \
  statics/real-esrgan-ncnn-webassembly-simd-threads.worker.js \
  models/manifest.json \
  models/real-esrgan-ncnn-webassembly-simd-threads.data; do
  if [ ! -s "$TMP_DIST/$asset" ]; then
    echo "Assembled site is incomplete: missing $asset" >&2
    exit 1
  fi
done

rm -rf ./dist.prev
if [ -e ./dist ]; then
  mv ./dist ./dist.prev
fi
if mv "$TMP_DIST" ./dist; then
  rm -rf ./dist.prev
else
  [ -e ./dist.prev ] && mv ./dist.prev ./dist
  echo "Failed to replace ./dist" >&2
  exit 1
fi
trap - EXIT INT TERM

echo "Build done. Site assembled in ./dist/"
echo "  dist/index.html   page entry"
echo "  dist/statics/     scripts, WASM, pthread worker, ORT runtime"
echo "  dist/models/      manifest.json, ONNX models, preloaded CPU .data"
echo "Serve ./dist/ over HTTP with COOP/COEP headers (see README); the directory is deployable on its own."

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
require_file "$WEB/img/sample-anime.webp" "Repository is incomplete: web/img/sample-anime.webp is missing."
require_file "$WEB/img/sample-photo.webp" "Repository is incomplete: web/img/sample-photo.webp is missing."
require_file "$ORT_DIR/ort.webgpu.min.js" "$PREPARE_HINT"
require_file "$ORT_DIR/ort-wasm-simd-threaded.asyncify.mjs" "$PREPARE_HINT"
require_file "$ORT_DIR/ort-wasm-simd-threaded.asyncify.wasm" "$PREPARE_HINT"
require_file "$ONNX_DIR/manifest.json" "$PREPARE_HINT"

for model in realesr-general-x4v3 realesr-animevideov3-x4 realesrgan-x4plus realesrgan-x4plus-anime; do
  require_file "./models/$model.param" "Missing CPU model $model. Run ./scripts/prepare_models.sh."
  require_file "./models/$model.bin" "Missing CPU model $model. Run ./scripts/prepare_models.sh."
  if ! grep -q '"name"[[:space:]]*:[[:space:]]*"'"$model"'"' "$ONNX_DIR/manifest.json"; then
    echo "Missing WebGPU model $model in $ONNX_DIR/manifest.json." >&2
    exit 1
  fi
done

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
cp -f ./LICENSE "$TMP_DIST/LICENSE"
cp -f ./NOTICE "$TMP_DIST/NOTICE"
cp -f "$WEB/robots.txt" "$TMP_DIST/robots.txt"
cp -f "$WEB/sitemap.xml" "$TMP_DIST/sitemap.xml"

cp -f "$WEB/wasmFeatureDetect.js" "$TMP_DIST/statics/"
# The showcase screenshots are published under statics/ so they pick up the same
# content-versioned, root-relative URLs as every other asset -- that keeps them
# cache-safe and reachable from the /<locale>/ routes.
mkdir -p "$TMP_DIST/statics/img"
cp -f "$WEB/img/sample-anime.webp" "$WEB/img/sample-photo.webp" "$TMP_DIST/statics/img/"
cp -f "$WEB/webgpu/realesrgan-webgpu.js" "$TMP_DIST/statics/webgpu/"

# ort.webgpu.min.js (1.27) is built with the asyncify wasm variant enabled;
# the jsep/jspi/plain variants are dead code in this bundle. Publish only what
# the bundle can actually request instead of copying ~78MB of unused WASM.
cp -f "$ORT_DIR/ort.webgpu.min.js" "$TMP_DIST/statics/ort/"
cp -f "$ORT_DIR/ort-wasm-simd-threaded.asyncify.mjs" "$TMP_DIST/statics/ort/"
cp -f "$ORT_DIR/ort-wasm-simd-threaded.asyncify.wasm" "$TMP_DIST/statics/ort/"

ARTIFACT=real-esrgan-ncnn-webassembly-simd-threads
for asset in "$ARTIFACT.js" "$ARTIFACT.wasm" "$ARTIFACT.worker.js"; do
  require_file "$BUILD/$asset" "Emscripten build did not produce $asset."
done
cp -f "$BUILD/$ARTIFACT.js" "$TMP_DIST/statics/"
cp -f "$BUILD/$ARTIFACT.wasm" "$TMP_DIST/statics/"
cp -f "$BUILD/$ARTIFACT.worker.js" "$TMP_DIST/statics/"

cp -f "$ONNX_DIR/manifest.json" "$TMP_DIST/models/"
cp -f "$ONNX_DIR"/*.onnx "$TMP_DIST/models/"
# CPU models are fetched one at a time and written into MEMFS at runtime. Keep
# them under the versioned models/ directory so they share HTTP cache busting.
for model in realesr-general-x4v3 realesr-animevideov3-x4 realesrgan-x4plus realesrgan-x4plus-anime; do
  cp -f "./models/$model.param" "$TMP_DIST/models/"
  cp -f "./models/$model.bin" "$TMP_DIST/models/"
done

# --- Cache-busting version directories -------------------------------------
# CDNs (Cloudflare in front of scaler.itools.top) and browsers cache statics/ and
# models/ for 30 days. Reusing the same URLs across deploys therefore keeps
# serving the previous build -- including copies cached before the origin sent
# COOP/COEP/CORP, which makes Chrome block the Emscripten pthread worker with
# "coep-frame-resource-needs-coep-header"; CPU WASM then never initializes and
# the page sticks on "正在加载 CPU WASM 与模型资源…". Deriving a directory name
# from the file contents gives every changed build its own URLs, so no cache
# can answer a request for the new build with an old response.
HASH_CMD=""
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
elif command -v openssl >/dev/null 2>&1; then
  HASH_CMD="openssl dgst -sha256"
fi

content_id() {
  if [ -n "$HASH_CMD" ]; then
    ( cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s\0' "$f"; cat "$f"; done ) \
      | $HASH_CMD \
      | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f][0-9a-f]+$/) { print substr($i, 1, 12); exit } }'
  else
    # POSIX fallback: cksum exists on every Linux/macOS box.
    ( cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; cksum < "$f"; done ) \
      | cksum | awk '{print $1 "-" $2}'
  fi
}

version_dir() {
  parent=$1
  version=$2
  mkdir -p "$parent/$version"
  for entry in "$parent"/*; do
    if [ "$entry" = "$parent/$version" ]; then
      continue
    fi
    mv "$entry" "$parent/$version/"
  done
}

rewrite_asset_paths() {
  sed -e "s|statics/|/statics/$STATIC_DIR/|g" \
      -e "s|models/|/models/$MODEL_DIR/|g" "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

check_versions() {
  file=$1
  for pair in "statics:$STATIC_DIR" "models:$MODEL_DIR"; do
    prefix=${pair%%:*}
    version=${pair##*:}
    versioned=$(grep -o "/$prefix/$version/" "$file" | wc -l | tr -d ' ')
    if [ "$versioned" = "0" ]; then
      echo "No versioned /$prefix/$version/ URL was written to $file." >&2
      exit 1
    fi
    # Any remaining bare prefix means a loadable path escaped the rewrite.
    bare=$(grep -oE "(^|[^/A-Za-z0-9_])$prefix/" "$file" | grep -v "/$version/" | wc -l | tr -d ' ')
    if [ "$bare" != "0" ]; then
      echo "Unversioned $prefix/ URL left in $file." >&2
      exit 1
    fi
  done
}

STATIC_DIR="v$(content_id "$TMP_DIST/statics")"
MODEL_DIR="v$(content_id "$TMP_DIST/models")"

version_dir "$TMP_DIST/statics" "$STATIC_DIR"
version_dir "$TMP_DIST/models" "$MODEL_DIR"

# Make every statics/ and models/ URL root-relative and versioned. The sed
# intentionally matches the bare prefixes anywhere, including inside single
# quoted JS strings; check_versions below then verifies nothing was missed.
rewrite_asset_paths "$TMP_DIST/index.html"
rewrite_asset_paths "$TMP_DIST/statics/$STATIC_DIR/webgpu/realesrgan-webgpu.js"
# Every locale uses root-relative, content-versioned assets. This avoids
# duplicating fragile ../ path rewriting for nested language routes. web/i18n.js
# is inlined into the page at build time, so each entry both ships every
# translation and (via scripts/prerender_locales.mjs) bakes the matching locale
# into <html lang>, <title>, metadata and the static body copy.
LOCALES="en zh-Hans zh-Hant fr de es pt ar ru ja ko"
if ! grep -q "Object.assign(T," "$TMP_DIST/index.html"; then
  echo "web/index.html does not inline the translation table (expected 'Object.assign(T, {')." >&2
  exit 1
fi

if command -v node >/dev/null 2>&1; then
  node scripts/prerender_locales.mjs "$TMP_DIST/index.html" "$WEB/i18n.js" "$TMP_DIST"
else
  # Without Node the translations are still inlined and the runtime picks the
  # route locale, but the head metadata and static copy stay English.
  echo "node not found: skipping locale prerender (pages fall back to runtime i18n)." >&2
  for locale in $LOCALES; do
    mkdir -p "$TMP_DIST/$locale"
    cp -f "$TMP_DIST/index.html" "$TMP_DIST/$locale/index.html"
  done
fi
check_versions "$TMP_DIST/index.html"
check_versions "$TMP_DIST/statics/$STATIC_DIR/webgpu/realesrgan-webgpu.js"
for locale in $LOCALES; do
  check_versions "$TMP_DIST/$locale/index.html"
done

for asset in \
  index.html \
  "statics/$STATIC_DIR/wasmFeatureDetect.js" \
  "statics/$STATIC_DIR/img/sample-anime.webp" \
  "statics/$STATIC_DIR/img/sample-photo.webp" \
  "statics/$STATIC_DIR/webgpu/realesrgan-webgpu.js" \
  "statics/$STATIC_DIR/ort/ort.webgpu.min.js" \
  "statics/$STATIC_DIR/ort/ort-wasm-simd-threaded.asyncify.wasm" \
  "statics/$STATIC_DIR/real-esrgan-ncnn-webassembly-simd-threads.js" \
  "statics/$STATIC_DIR/real-esrgan-ncnn-webassembly-simd-threads.wasm" \
  "statics/$STATIC_DIR/real-esrgan-ncnn-webassembly-simd-threads.worker.js" \
  "models/$MODEL_DIR/manifest.json"; do
  if [ ! -s "$TMP_DIST/$asset" ]; then
    echo "Assembled site is incomplete: missing $asset" >&2
    exit 1
  fi
done
for model in realesr-general-x4v3 realesr-animevideov3-x4 realesrgan-x4plus realesrgan-x4plus-anime; do
  for ext in param bin; do
    if [ ! -s "$TMP_DIST/models/$MODEL_DIR/$model.$ext" ]; then
      echo "Assembled site is incomplete: missing CPU model $model.$ext" >&2
      exit 1
    fi
  done
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
echo "  dist/index.html              page entry"
echo "  dist/statics/$STATIC_DIR/    scripts, WASM, pthread worker, ORT runtime"
echo "  dist/models/$MODEL_DIR/      manifest.json, ONNX and CPU param/bin models"
echo "The v* directories are content-derived, so a deploy always gets fresh URLs"
echo "and neither a browser nor a CDN cache can serve a previous build."
echo "Serve ./dist/ over HTTP with COOP/COEP headers (see README); the directory is deployable on its own."

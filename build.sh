#!/bin/sh
# Build Real-ESRGAN ncnn WebAssembly (Route A: CPU)
set -e

if [ -z "$EMSDK" ]; then
  echo "EMSDK is not set. Install emsdk and run: source ./emsdk_env.sh" >&2
  exit 1
fi

if [ ! -f ./ncnn/CMakeLists.txt ]; then
  echo "Submodule ncnn missing. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! ls ./models/*.bin >/dev/null 2>&1; then
  echo "No models in ./models/. Run: powershell -File ./scripts/download_models.ps1" >&2
  exit 1
fi

mkdir -p ./build
cd ./build

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
cp real-esrgan-ncnn-webassembly-* ../web/
echo "Build done. Artifacts copied to web/"

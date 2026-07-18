# Build Real-ESRGAN ncnn WebAssembly (Route A: CPU)
# Prerequisites: emsdk activated ($env:EMSDK set), CMake, Ninja (recommended), submodules, models.

$ErrorActionPreference = "Stop"

if (-not $env:EMSDK) {
    Write-Error "EMSDK is not set. Install emsdk, then run: .\emsdk_env.ps1"
}

if (-not (Test-Path ".\ncnn\CMakeLists.txt")) {
    Write-Error "Submodule ncnn missing. Run: git submodule update --init --recursive"
}

$modelBins = Get-ChildItem ".\models\*.bin" -ErrorAction SilentlyContinue
if (-not $modelBins -or $modelBins.Count -eq 0) {
    Write-Error "No models in .\models\. Run: powershell -File .\scripts\download_models.ps1"
}

New-Item -ItemType Directory -Force -Path .\build | Out-Null
Push-Location .\build

$toolchain = Join-Path $env:EMSDK "upstream\emscripten\cmake\Modules\Platform\Emscripten.cmake"
if (-not (Test-Path $toolchain)) {
    Pop-Location
    Write-Error "Emscripten toolchain not found: $toolchain"
}

$cmakeArgs = @(
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    "-DWASM_FEATURE=simd-threads",
    "-DNCNN_THREADS=ON",
    "-DNCNN_OPENMP=ON",
    "-DNCNN_SIMPLEOMP=ON",
    "-DNCNN_RUNTIME_CPU=OFF",
    "-DNCNN_SSE2=ON",
    "-DNCNN_AVX2=OFF",
    "-DNCNN_AVX=OFF",
    "-DNCNN_VULKAN=OFF",
    "-DNCNN_BUILD_TOOLS=OFF",
    "-DNCNN_BUILD_EXAMPLES=OFF",
    "-DNCNN_BUILD_BENCHMARK=OFF"
)

cmake (@($cmakeArgs + @("-G", "Ninja", "..")) )
if ($LASTEXITCODE -ne 0) {
    Write-Host "Ninja generator failed, trying default generator..."
    cmake (@($cmakeArgs + @("..")))
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        Write-Error "cmake configure failed"
    }
}

cmake --build . -j 4
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Write-Error "cmake build failed"
}

Copy-Item -Force .\real-esrgan-ncnn-webassembly-* ..\web\
Pop-Location
Write-Host "Build done. Artifacts copied to web/"

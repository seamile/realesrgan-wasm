# Prepare ONNX models + onnxruntime-web assets for Route B (WebGPU).
# Usage: powershell -File .\scripts\prepare_webgpu_models.ps1

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$weights = Join-Path $root "_convert\weights"
$onnxDir = Join-Path $root "web\models-onnx"
$ortDir = Join-Path $root "web\ort"
New-Item -ItemType Directory -Force -Path $weights, $onnxDir, $ortDir | Out-Null

function Download-IfNeeded($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 1000) {
        Write-Host "Skip $(Split-Path $out -Leaf)"
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf) ..."
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

# ---- PyTorch weights ----
Download-IfNeeded `
  "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth" `
  (Join-Path $weights "realesr-animevideov3.pth")

Download-IfNeeded `
  "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth" `
  (Join-Path $weights "realesr-general-x4v3.pth")

$x2pth = Join-Path $root "_convert\RealESRGAN_x2plus.pth"
if (-not (Test-Path $x2pth)) {
    Download-IfNeeded `
      "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" `
      $x2pth
}

# ---- Export ONNX (fixed spatial size = tilesize + 2*prepadding; required by ORT WebGPU) ----
$py = Join-Path $PSScriptRoot "pytorch2onnx_webgpu.py"

# Force re-export when this script is used to fix model shape issues.
Get-ChildItem $onnxDir -Filter "*.onnx" -ErrorAction SilentlyContinue | Remove-Item -Force

function Export-Onnx($argsList, $outName) {
    Write-Host "Exporting $outName ..."
    & python $py @argsList
    if ($LASTEXITCODE -ne 0) { throw "export failed: $outName" }
}

# tilesize=128, prepadding=10 → fixed input 148x148
Export-Onnx @(
    "--arch", "anime-scaled",
    "--input", (Join-Path $weights "realesr-animevideov3.pth"),
    "--output", (Join-Path $onnxDir "realesr-animevideov3-x2.onnx"),
    "--scale", "2",
    "--size", "148"
) "realesr-animevideov3-x2.onnx"

Export-Onnx @(
    "--arch", "anime-scaled",
    "--input", (Join-Path $weights "realesr-animevideov3.pth"),
    "--output", (Join-Path $onnxDir "realesr-animevideov3-x3.onnx"),
    "--scale", "3",
    "--size", "148"
) "realesr-animevideov3-x3.onnx"

Export-Onnx @(
    "--arch", "anime-scaled",
    "--input", (Join-Path $weights "realesr-animevideov3.pth"),
    "--output", (Join-Path $onnxDir "realesr-animevideov3-x4.onnx"),
    "--scale", "4",
    "--size", "148"
) "realesr-animevideov3-x4.onnx"

Export-Onnx @(
    "--arch", "srvgg",
    "--input", (Join-Path $weights "realesr-general-x4v3.pth"),
    "--output", (Join-Path $onnxDir "realesr-general-x4v3.onnx"),
    "--scale", "4",
    "--num-conv", "32",
    "--size", "148"
) "realesr-general-x4v3.onnx"

# tilesize=64, prepadding=10 → 84 (already even for pixel_unshuffle)
Export-Onnx @(
    "--arch", "rrdb",
    "--input", $x2pth,
    "--output", (Join-Path $onnxDir "realesrgan-x2plus.onnx"),
    "--scale", "2",
    "--num-block", "23",
    "--size", "84"
) "realesrgan-x2plus.onnx"

# ---- manifest ----
$manifest = @{
    version = 1
    backend = "webgpu"
    models = @(
        @{ name = "realesr-animevideov3-x2"; file = "realesr-animevideov3-x2.onnx"; scale = 2; input = "data"; output = "output"; tilesize = 128; prepadding = 10; align = 1 },
        @{ name = "realesr-animevideov3-x3"; file = "realesr-animevideov3-x3.onnx"; scale = 3; input = "data"; output = "output"; tilesize = 128; prepadding = 10; align = 1 },
        @{ name = "realesr-animevideov3-x4"; file = "realesr-animevideov3-x4.onnx"; scale = 4; input = "data"; output = "output"; tilesize = 128; prepadding = 10; align = 1 },
        @{ name = "realesr-general-x4v3"; file = "realesr-general-x4v3.onnx"; scale = 4; input = "data"; output = "output"; tilesize = 128; prepadding = 10; align = 1 },
        @{ name = "realesrgan-x2plus"; file = "realesrgan-x2plus.onnx"; scale = 2; input = "data"; output = "output"; tilesize = 64; prepadding = 10; align = 2 }
    )
} | ConvertTo-Json -Depth 5
Set-Content -Path (Join-Path $onnxDir "manifest.json") -Value $manifest -Encoding UTF8
Write-Host "Wrote manifest.json"

# ---- onnxruntime-web (vendor for offline / COOP pages) ----
Push-Location $root
if (-not (Test-Path "package.json")) {
    @"
{
  "name": "real-esrgan-ncnn-webassembly",
  "private": true,
  "dependencies": {
    "onnxruntime-web": "^1.22.0"
  }
}
"@ | Set-Content package.json -Encoding UTF8
}
npm install --no-fund --no-audit
if ($LASTEXITCODE -ne 0) { throw "npm install failed" }

$ortSrc = Join-Path $root "node_modules\onnxruntime-web\dist"
# ORT picks its wasm variant (jsep/asyncify/jspi/plain) at runtime, so ship all of them.
Get-ChildItem $ortDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Copy-Item (Join-Path $ortSrc "ort.webgpu.min.js") $ortDir -Force
Copy-Item (Join-Path $ortSrc "ort.webgpu.min.js.map") $ortDir -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $ortSrc "ort-wasm-simd-threaded.*") $ortDir -Force
Get-ChildItem $ortDir | ForEach-Object { Write-Host "Copied $($_.Name)" }
Pop-Location

Write-Host "Done. ONNX models in web/models-onnx , ORT in web/ort"

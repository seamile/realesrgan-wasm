# Download default (small) ncnn models into .\models/
# Everything in models/ is packed into the WASM .data on next build.
#
# Usage:
#   powershell -File .\scripts\download_models.ps1
#   powershell -File .\scripts\download_models.ps1 -IncludeWdn
#
# Large realesrgan-x2plus is NOT downloaded here (HF dumps may contain Shape ops).
# Convert it with the official pipeline: scripts\convert_x2plus.ps1

param(
    [switch]$IncludeWdn
)

$ErrorActionPreference = "Stop"
$dest = Join-Path $PSScriptRoot "..\models"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Download-IfNeeded($url, $out) {
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 1000) {
        Write-Host "Skip $(Split-Path $out -Leaf)"
        return
    }
    Write-Host "Downloading $(Split-Path $out -Leaf) ..."
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

# ---- general-x4v3 (photo, ~4.6MB) ----
$base = "https://github.com/TransparentLC/realesrgan-gui/releases/download/additional-models"
Download-IfNeeded "$base/realesr-general-x4v3.bin" (Join-Path $dest "realesr-general-x4v3.bin")
Download-IfNeeded "$base/realesr-general-x4v3.param" (Join-Path $dest "realesr-general-x4v3.param")

if ($IncludeWdn) {
    Download-IfNeeded "$base/realesr-general-wdn-x4v3.bin" (Join-Path $dest "realesr-general-wdn-x4v3.bin")
    Download-IfNeeded "$base/realesr-general-wdn-x4v3.param" (Join-Path $dest "realesr-general-wdn-x4v3.param")
}

# ---- animevideov3 x2/x3/x4 from official ncnn-vulkan package ----
$zip = Join-Path $env:TEMP "realesrgan-ncnn-windows.zip"
$extract = Join-Path $env:TEMP "realesrgan-ncnn-extract"
$url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip"
Write-Host "Downloading official package for animevideov3..."
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $extract -Force
Get-ChildItem -Recurse $extract -Filter "realesr-animevideov3-*" |
    ForEach-Object { Copy-Item $_.FullName $dest -Force; Write-Host "Copied $($_.Name)" }

Write-Host ""
Write-Host "Done. Models in $dest"
Write-Host "Note: everything in models/ is packed into the WASM .data on next build."
Write-Host "Optional large x2plus (CPU): powershell -File .\scripts\convert_x2plus.ps1"
Write-Host "Optional WebGPU ONNX:       powershell -File .\scripts\prepare_webgpu_models.ps1"

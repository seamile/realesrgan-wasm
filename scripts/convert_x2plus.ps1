# Official-style conversion: RealESRGAN_x2plus.pth -> clean ncnn model
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$conv = Join-Path $root "_convert"
$toolsOnnx = Join-Path $conv "ncnn-old\ncnn-20230223-windows-vs2019\x64\bin\onnx2ncnn.exe"
$toolsOpt = Join-Path $conv "ncnn-windows\ncnn-20260526-windows-vs2022\x64\bin\ncnnoptimize.exe"
$pth = Join-Path $conv "RealESRGAN_x2plus.pth"
$onnx = Join-Path $conv "realesrgan-x2plus.onnx"
$rawParam = Join-Path $conv "realesrgan-x2plus-raw.param"
$rawBin = Join-Path $conv "realesrgan-x2plus-raw.bin"
$optParam = Join-Path $conv "realesrgan-x2plus.param"
$optBin = Join-Path $conv "realesrgan-x2plus.bin"
$dest = Join-Path $root "models"

if (-not (Test-Path $toolsOnnx)) { throw "onnx2ncnn not found: $toolsOnnx" }
if (-not (Test-Path $toolsOpt)) { throw "ncnnoptimize not found: $toolsOpt" }
if (-not (Test-Path $pth)) { throw "missing $pth" }

Write-Host "==> PyTorch -> ONNX"
python (Join-Path $PSScriptRoot "pytorch2onnx_x2plus.py") --input $pth --output $onnx --scale 2 --size 64

Write-Host "==> ONNX -> ncnn (raw)"
& $toolsOnnx $onnx $rawParam $rawBin
if ($LASTEXITCODE -ne 0) { throw "onnx2ncnn failed" }

Write-Host "==> ncnnoptimize (fp16 flag=1 as official docs)"
& $toolsOpt $rawParam $rawBin $optParam $optBin 1
if ($LASTEXITCODE -ne 0) { throw "ncnnoptimize failed" }

Write-Host "==> Ensure blob names data/output"
$paramText = Get-Content $optParam -Raw
# Input line: keep/rename last blob to data
$paramText = [regex]::Replace($paramText, '(?m)^(Input\s+\S+\s+0\s+1\s+)\S+', '${1}data')
# If final output blob is not named output, user may need manual fix; try common renames
if ($paramText -notmatch '(?m)\soutput(\s|$)') {
    Write-Host "WARNING: no blob named 'output' found; check param manually"
}

# Rewrite references from old input name 'input' if still present as standalone blob after Input rename
# (onnx export already used data/output names)
Set-Content -Path $optParam -Value $paramText -NoNewline

Write-Host "==> Layer type summary"
Select-String -Path $optParam -Pattern '^[A-Za-z]+' | ForEach-Object { ($_.Line -split '\s+')[0] } |
  Group-Object | Sort-Object Count -Descending | Select-Object -First 20 | Format-Table Name,Count

if ($paramText -match '(?m)^Shape\b') {
    Write-Host "WARNING: Shape layer still present after conversion"
} else {
    Write-Host "OK: no Shape layer"
}

Copy-Item $optParam (Join-Path $dest "realesrgan-x2plus.param") -Force
Copy-Item $optBin (Join-Path $dest "realesrgan-x2plus.bin") -Force
Write-Host "Installed to $dest"
Get-Item (Join-Path $dest "realesrgan-x2plus.*") | Format-Table Name,Length

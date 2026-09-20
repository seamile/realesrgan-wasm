# models-onnx/ — Route B (WebGPU)

Browser WebGPU inference uses `.onnx` files here via [onnxruntime-web](https://onnxruntime.ai/).

## Generate

Windows PowerShell：

```powershell
powershell -File .\scripts\prepare_webgpu_models.ps1
```

Linux：

```bash
./scripts/prepare_webgpu_models.sh
```

This will:

1. Download official `.pth` weights
2. Export **fixed-shape** ONNX into this directory (required: ORT WebGPU breaks if input/output share the same dynamic dim names)
3. Write `manifest.json`
4. Copy onnxruntime-web assets to `web/ort/`

`.onnx` files are gitignored; keep `manifest.json` and this README in Git.

## Notes

- I/O blob names: `data` / `output`
- Tile size in the page must match export size (`tilesize + 2 * prepadding`)
- `realesrgan-x2plus.onnx` is large (~67MB); drop it for smaller demos

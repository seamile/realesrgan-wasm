# models-onnx/ — Route B (WebGPU)

Browser WebGPU inference uses `.onnx` files here via [onnxruntime-web](https://onnxruntime.ai/).

## Generate

```bash
./scripts/prepare_webgpu_models.sh
```

This will:

1. Download official `.pth` weights
2. Export **fixed-shape** ONNX into this directory (required: ORT WebGPU breaks if input/output share the same dynamic dim names)
3. Write `manifest.json`
4. Copy onnxruntime-web assets to `web/ort/`

The build step (`./build.sh`) then packages this directory as `dist/models/`.

`.onnx` files are gitignored; keep `manifest.json` and this README in Git.

## Notes

- I/O blob names: `data` / `output`
- Tile size in the page must match export size (`tilesize + 2 * prepadding`)
- The production manifest contains four fixed 4x models. Keep the manifest and
  CPU `models/` directory in sync when preparing a release.
- `realesrgan-x4plus-anime` is the 6-block RRDB ("6B") variant; it must be exported with
  `--num-block 6`.
- `realesrgan-x4plus.pth` only exists in the `v0.1.0` release tag, not `v0.2.2.4`.

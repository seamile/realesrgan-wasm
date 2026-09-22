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
- `realesrgan-x2plus.onnx` and `realesrgan-x4plus.onnx` are large (~67MB each);
  `realesrgan-x4plus-anime.onnx` is ~18MB. Drop the ones you do not need for smaller demos.
- `realesrgan-x4plus` has no `pixel_unshuffle`, so its RRDB body runs at the full tile
  resolution while x2plus runs it at half resolution: at the same `tilesize` it uses about
  4x the body activations. If a GPU is memory-tight, lower `tilesize` (and re-export with the
  matching `--size`) rather than changing the manifest alone.
- `realesrgan-x4plus-anime` is the 6-block RRDB ("6B") variant; it must be exported with
  `--num-block 6`.
- `realesrgan-x4plus.pth` only exists in the `v0.1.0` release tag, not `v0.2.2.4`.

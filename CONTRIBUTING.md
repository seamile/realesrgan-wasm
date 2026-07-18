# Contributing

Thanks for your interest in improving this project.

## Before opening a PR

1. Keep Route A (ncnn WASM) working: `build.ps1` / `build.sh` + `go run local_server.go`
2. Do **not** commit model weights, `web/*.data`, `web/ort/`, `node_modules/`, or `_convert/`
3. Prefer small, focused changes with a short description of *why*
4. If you touch WebGPU models, re-export with `scripts/prepare_webgpu_models.ps1` (fixed-shape ONNX)

## Development tips

- Use `local_server.go` so SharedArrayBuffer / pthread works
- On Windows dual-GPU laptops, force Chrome onto the discrete GPU when benchmarking WebGPU
- Match coding style of nearby files; avoid drive-by refactors

## Reporting issues

Include: OS, browser version, backend (WebGPU/CPU), model name, image size, and console errors.

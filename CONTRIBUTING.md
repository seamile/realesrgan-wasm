# Contributing

Thanks for your interest in improving this project.

## Before opening a PR

1. Keep Route A (ncnn WASM) working: `./build.sh` assembles `dist/`, served by `go run local_server.go`
2. Do **not** commit model weights, `dist/`, `web/ort/`, `node_modules/`, or `_convert/`
3. Prefer small, focused changes with a short description of *why*
4. If you touch WebGPU models, re-export with `./scripts/prepare_webgpu_models.sh` (fixed-shape ONNX)

## Development tips

- Use `local_server.go` (serves `dist/`) so SharedArrayBuffer / pthread works
- Target Linux / macOS; keep `build.sh` and the `scripts/*.sh` helpers POSIX-friendly
- Match coding style of nearby files; avoid drive-by refactors

## Reporting issues

Include: OS, browser version, backend (WebGPU/CPU), model name, image size, and console errors.

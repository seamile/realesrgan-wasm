# Real-ESRGAN ncnn WebAssembly

Run [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) locally in the browser (no image upload).

| Route | Backend | Notes |
|-------|---------|--------|
| **A** | ncnn + WASM (SIMD + threads) | Broad compatibility, fallback |
| **B** | ONNX Runtime WebGPU | Faster on discrete GPUs; falls back to A |

Runtime preference: **WebGPU �?CPU WASM**. Upstream ncnn browser WebGPU is not ready yet, so Route B uses [onnxruntime-web](https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html).

中文文档：[README.md](README.md)

## Quick start

```bash
git clone --recursive https://github.com/panmeibing/real-esrgan-ncnn-webassembly.git
cd real-esrgan-ncnn-webassembly

# 1) Default small CPU models (PowerShell on Windows; or adapt the script)
powershell -File ./scripts/download_models.ps1

# 2) Activate Emscripten, then build Route A
#    Windows:  .\emsdk_env.ps1   then   powershell -File .\build.ps1
#    Linux/macOS: source emsdk_env.sh && sh build.sh

# 3) Optional WebGPU assets (Python+PyTorch+Node)
powershell -File ./scripts/prepare_webgpu_models.ps1

# 4) Serve with COOP/COEP (required for WASM threads)
go run local_server.go
# open http://localhost:8000
```

### Requirements

- Git, CMake, Emscripten 3.1.28+, Ninja (recommended)
- Go (for `local_server.go`) or any static server that sets COOP/COEP
- Optional: Python 3 + PyTorch, Node.js (WebGPU prep only)
- Desktop Chrome/Edge/Firefox; **no iOS**

### Windows dual-GPU note

Chrome often binds WebGPU to the **integrated** GPU and ignores `powerPreference`. Enable `chrome://flags/#force-high-performance-gpu` or set Chrome to High performance in Windows Graphics settings, then fully restart Chrome.

### Adding models

- **CPU:** put `.param`+`.bin` in `models/`, rebuild.
- **WebGPU:** put fixed-shape `.onnx` under `web/models-onnx/` and update `manifest.json`.

Weights and build artifacts are gitignored; see scripts under `scripts/`.

## License

BSD 3-Clause �?see [LICENSE](LICENSE) and [NOTICE](NOTICE).

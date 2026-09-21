# Real-ESRGAN ncnn WebAssembly

Run [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) locally in the browser (no image upload).

| Route | Backend | Notes |
|-------|---------|--------|
| **A** | ncnn + WASM (SIMD + threads) | Broad compatibility, fallback |
| **B** | ONNX Runtime WebGPU | Faster on discrete GPUs; falls back to A |

Runtime preference: **WebGPU, falling back to CPU WASM**. Upstream ncnn browser WebGPU is not ready yet, so Route B uses [onnxruntime-web](https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html).

中文文档：[README.md](README.md)

## Quick start

```bash
git clone --recursive https://github.com/panmeibing/real-esrgan-ncnn-webassembly.git
cd real-esrgan-ncnn-webassembly

# 1) Default small CPU models
./scripts/download_models.sh

# 2) WebGPU publish assets (Python + PyTorch + Node.js; required for the first release build)
./scripts/prepare_webgpu_models.sh

# 3) Activate Emscripten, then build Route A and assemble dist/
source /path/to/emsdk/emsdk_env.sh
./build.sh

# 4) Serve dist/ with COOP/COEP (required for WASM threads)
go run local_server.go
# open http://localhost:8000
```

`build.sh` writes a self-contained site to `dist/`:

```text
dist/
├── index.html
├── statics/   # wasmFeatureDetect.js, webgpu/, ort/, and real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .worker.js
└── models/    # manifest.json, *.onnx, real-esrgan-ncnn-webassembly-simd-threads.data
```

`dist/` can be moved and deployed on its own. If ORT or ONNX inputs are missing, the build fails
before replacing an existing `dist/` and tells you which preparation script to run.

### Requirements

- Git, CMake, Emscripten 3.1.28+, Ninja (recommended)
- Go (for `local_server.go`) or any static server that sets COOP/COEP (e.g. nginx)
- Python 3 + PyTorch and Node.js to generate WebGPU assets (not needed again while those assets remain prepared)
- Linux / macOS
- Desktop Chrome/Edge/Firefox; **no iOS**

## Deploying to nginx

`dist/` is a static site, so nginx can serve it directly — the Go server is not needed:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name example.com;

    ssl_certificate     /etc/nginx/ssl/example.pem;
    ssl_certificate_key /etc/nginx/ssl/example.key;

    root /var/www/real-esrgan;   # contents of dist/
    index index.html;

    # Required for WASM threads (SharedArrayBuffer)
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Embedder-Policy "require-corp" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

All three headers are required for the page to be `crossOriginIsolated`; without them the CPU
backend cannot use threads. The nginx user must be able to read `dist/` (copy it to `/var/www/`
rather than serving it from a home directory), then run `nginx -t && systemctl reload nginx`.

### Adding models

- **CPU:** put `.param`+`.bin` in `models/`, then re-run `./build.sh`.
- **WebGPU:** put fixed-shape `.onnx` under `web/models-onnx/`, update `manifest.json`, then re-run `./build.sh`.

Weights and build artifacts are gitignored; see scripts under `scripts/`.

## License

BSD 3-Clause — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

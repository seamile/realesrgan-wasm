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

# 1) Install the Emscripten SDK once; build.sh loads its environment automatically
(cd emsdk && ./emsdk install 3.1.28 && ./emsdk activate 3.1.28)

# 2) Default CPU models (6 models, ~49MB; the same list as the WebGPU manifest)
./scripts/download_models.sh

# 3) WebGPU publish assets (Python 3 + PyTorch + onnx + Node.js; required for the first release build)
#    --skip-x2plus keeps the WebGPU list identical to the CPU one above
./scripts/prepare_webgpu_models.sh --skip-x2plus

# 4) Build Route A and assemble dist/
./build.sh

# 5) Serve dist/ with COOP/COEP (required for WASM threads)
go run local_server.go
# open http://localhost:8000
```

`build.sh` writes a self-contained site to `dist/`:

```text
dist/
├── index.html
├── statics/v<content-hash>/   # wasmFeatureDetect.js, webgpu/, ort/, and real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .worker.js
└── models/v<content-hash>/    # manifest.json, *.onnx, real-esrgan-ncnn-webassembly-simd-threads.data
```

`statics/` and `models/` each contain a content-hash subdirectory (`v…`) and `index.html` only
references those versioned paths: **change the assets and the URLs change**. No browser cache and
no CDN (Cloudflare, etc.) can answer a request for a new build with a response cached for an older
one. This matters for the CPU backend: static assets are normally cached for 30 days, and an old
response without a `Cross-Origin-Embedder-Policy` header makes Chrome block the pthread worker, so
the page hangs on "正在加载 CPU WASM 与模型资源…". Unchanged assets keep their hash and stay cached.

`dist/` can be moved and deployed on its own. If ORT or ONNX inputs are missing, the build fails
before replacing an existing `dist/` and tells you which preparation script to run.

### Requirements

- Linux / macOS.
- Git, CMake 3.10+, a C/C++ toolchain and Emscripten **3.1.28**. `build.sh` uses the default CMake
  generator (Ninja is not required) and hardcodes `-j4`.
- `curl` or `wget` to download models and ORT assets, plus `unzip` or Python 3 to unpack the official
  ncnn model zip. `build.sh` also needs one of `sha256sum` / `shasum` / `openssl` for the content-hash
  directory names.
- Go (**optional**) for `local_server.go`, or any static server that sets COOP/COEP (e.g. nginx).
- Python 3 + PyTorch + onnx, and Node.js, to generate WebGPU assets (`prepare_webgpu_models.sh`); not
  needed again while those assets remain prepared.
- `protoc` + libprotobuf + a C++17 compiler (macOS `brew install protobuf`, Debian/Ubuntu
  `apt install protobuf-compiler libprotobuf-dev`) only for `build_ncnn_tools.sh`, which builds
  `onnx2ncnn` — needed for a CPU `realesrgan-x2plus`.
- Desktop Chrome/Edge/Firefox; **no iOS**.

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

    # Long caching is safe: URLs carry a content hash, so a new build never
    # reuses a stale entry. Note that nginx `add_header` replaces rather than
    # inherits -- any `add_header` inside a location drops all three headers
    # above and Chrome then blocks the same-origin pthread worker with
    # ERR_BLOCKED_BY_RESPONSE / coep-frame-resource-needs-coep-header.
    # Use `expires` (a different module) for cache policy, never add_header.
    location /statics/ {
        expires 30d;
        try_files $uri =404;
    }

    location /models/ {
        expires 30d;
        try_files $uri =404;
    }

    # The entry HTML must be revalidated so new asset paths are picked up.
    location = /index.html {
        expires -1;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

All three headers are required for the page to be `crossOriginIsolated`, and they must cover every
path including `/statics/` (worker scripts especially). Without them the CPU backend cannot use
threads. `.wasm` must be served as `application/wasm` and `.mjs` as JavaScript, or ORT's dynamic
`import()` is rejected. The nginx user must be able to read `dist/` (copy it to `/var/www/` rather
than serving it from a home directory), then run `nginx -t && systemctl reload nginx`.

### Behind Cloudflare

- Assets are cached at the edge. Content-hashed URLs bypass old copies, but paths cached by an
  earlier deploy only disappear after their TTL or a dashboard Purge Cache.
- Disable **Rocket Loader** for the site: it fetches and `eval`s scripts itself, leaving
  `document.currentScript` empty and breaking loaders that depend on the script path (the frontend
  now pins `mainScriptUrlOrBlob` as a fallback, but off is safer).
- Check `crossOriginIsolated` in the console after loading the page; it must be `true`.

### Adding models

- **CPU:** put `.param`+`.bin` in `models/`, then re-run `./build.sh`.
- **WebGPU:** put fixed-shape `.onnx` under `web/models-onnx/`, update `manifest.json`, then re-run `./build.sh`.

`prepare_webgpu_models.sh` exports `realesr-animevideov3-x2/x3/x4`, `realesr-general-x4v3`, `realesrgan-x4plus` (~67MB) and `realesrgan-x4plus-anime` (~18MB); drop `--skip-x2plus` to also export `realesrgan-x2plus` (~67MB). Keep both backends in sync: either skip x2plus on the WebGPU side, or add it to the CPU side with `./scripts/build_ncnn_tools.sh` + `./scripts/convert_x2plus.sh` (official weights only — third-party "rough" ONNX conversions tend to contain `Shape` layers). `build.sh` copies every model listed in `manifest.json` into `dist/models/`; delete the large ones you do not ship before building.
`realesrgan-x4plus` skips `pixel_unshuffle`, so its RRDB body runs at full tile resolution — about
4x the body activations of x2plus at the same `tilesize`.

Weights and build artifacts are gitignored; see scripts under `scripts/`.

## License

BSD 3-Clause — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

# Scaler

Upscale photos and anime images 4× in the browser: [scaler.itools.top](https://scaler.itools.top/). Images are processed on your own machine and are never uploaded or stored.

The algorithm and models come from [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN); the source repository is [seamile/realesrgan-wasm](https://github.com/seamile/realesrgan-wasm).

| Route | Backend | Notes |
|-------|---------|--------|
| **A** | ncnn compiled to Emscripten WebAssembly (SIMD + pthreads) | Broad compatibility, fallback |
| **B** | onnxruntime-web WebGPU execution provider | GPU acceleration |

Automatic mode tries WebGPU first and falls back to CPU when WebGPU is unavailable, fails to initialize, or fails to process; the forced modes never fall back.

Privacy: pixels are processed in browser memory on your own CPU/GPU. The app uploads and stores nothing — a result is written to disk only when you download it. The page still fetches its code, runtimes and the selected model over the network.

中文文档：[README.md](README.md)

## Quick start

```bash
git clone --recursive https://github.com/seamile/realesrgan-wasm.git
cd realesrgan-wasm

# 1) Install the Emscripten SDK once; build.sh loads its environment automatically
(cd emsdk && ./emsdk install 3.1.28 && ./emsdk activate 3.1.28)

# 2) Prepare the four production CPU models, the ONNX models and web/ort/
#    (Python 3 + PyTorch + onnx + Node.js; required for the first release build.
#    This also runs download_models.sh, so CPU-only setups need nothing else.)
./scripts/prepare_models.sh

# 3) Build Route A and assemble dist/
./build.sh

# 4) Serve dist/ with COOP/COEP (required for WASM threads)
go run ./local_server.go
# open http://localhost:8000
```

`build.sh` writes a self-contained site to `dist/`:

```text
dist/
├── index.html                 # root entry (English static copy, runtime language match)
├── <locale>/index.html        # en zh-Hans zh-Hant fr de es pt ar ru ja ko: prerendered localized entries
├── LICENSE / NOTICE / robots.txt / sitemap.xml
├── statics/v<content-hash>/   # wasmFeatureDetect.js, webgpu/, ort/, img/, and real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .worker.js
└── models/v<content-hash>/    # manifest.json, *.onnx, CPU *.param/*.bin (downloaded on demand)
```

`scripts/prerender_locales.mjs` bakes `<html lang>`, `<title>`, description, canonical/hreflang,
Open Graph, JSON-LD and the static body copy into every locale entry. The page also carries an
inlined translation table for runtime language switching, so it never requests `i18n.js`
separately.

`statics/` and `models/` each contain a content-hash subdirectory (`v…`) and `index.html` only
references those versioned paths: **change the assets and the URLs change**. No browser cache and
no CDN (Cloudflare, etc.) can answer a request for a new build with a response cached for an older
one. This matters for the CPU backend: static assets are normally cached for 30 days, and an old
response without a `Cross-Origin-Embedder-Policy` header makes Chrome block the pthread worker, so
the page hangs on "Loading CPU engine…". Unchanged assets keep their hash and stay cached.

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

### Input and output

PNG, JPEG, WebP, BMP, AVIF and GIF inputs are accepted; results download as PNG, and an animated GIF is upscaled from its first frame only. To limit runtime and memory use, keep the longest edge at or below 512px on CPU or 1024px on WebGPU — these are recommendations, not hard limits. Past roughly 4 million pixels the UI warns that processing may be slow or run out of memory.

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

### Model choices

The UI exposes exactly four 4× choices, matched from "image style × preference":

| Style | Speed first | Quality first |
|-------|-------------|---------------|
| Real photo | `realesr-general-x4v3` | `realesrgan-x4plus` |
| Anime | `realesr-animevideov3-x4` | `realesrgan-x4plus-anime` |

CPU and WebGPU use the same model names.

`prepare_models.sh` prepares those four models for both backends (`realesrgan-x4plus` ~67MB, `realesrgan-x4plus-anime` ~18MB). `build.sh` copies the manifest's ONNX files and the CPU `.param`/`.bin` files into `dist/models/`; the page downloads only the selected model at runtime.
`realesrgan-x4plus` skips `pixel_unshuffle`, so its RRDB body runs at full tile resolution — about
4x the body activations of x2plus at the same `tilesize`.

### Adding a model (a developer change)

Adding a model means changing code, not just dropping files into a directory:

- **CPU:** put the `.param`+`.bin` pair in `models/`, then add its name to **both** CPU model loops in `build.sh` (the copy loop and the validation loop).
- **WebGPU:** add a fixed-shape `.onnx` under `web/models-onnx/`, update `manifest.json`, then re-run `./build.sh`.
- **Frontend:** wire the new name into the model map in `web/index.html` (`map={photo:{speed:…,quality:…},anime:{speed:…,quality:…}}`), otherwise users cannot select it. A scale other than 4× also needs the output sizing and download logic updated.

The `realesrgan-x2plus` conversion scripts (`build_ncnn_tools.sh`, `convert_x2plus.sh`) are kept for development only: the published UI and `build.sh` are fixed to the four 4× models above, so their output does not appear on the site without the changes described here.

Weights and build artifacts are gitignored; see scripts under `scripts/`.

## Acknowledgements

This project builds on:

- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) — models and algorithm
- [panmeibing/real-esrgan-ncnn-webassembly](https://github.com/panmeibing/real-esrgan-ncnn-webassembly) — the WebAssembly implementation this project is based on
- [hanFengSan/realcugan-ncnn-webassembly](https://github.com/hanFengSan/realcugan-ncnn-webassembly) — Emscripten + ncnn browser engineering reference
- [Tencent/ncnn](https://github.com/Tencent/ncnn) — CPU inference framework
- [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime) — WebGPU execution provider

## License

BSD 3-Clause — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

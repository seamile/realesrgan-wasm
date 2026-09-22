# Real-ESRGAN ncnn WebAssembly

在浏览器本地运行 [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 超分辨率（照片 / 动漫增强），**不上传图片**。

| 路线 | 后端 | 说明 |
|------|------|------|
| **A** | ncnn + WebAssembly（SIMD + 多线程） | 兼容面广，默认兜底 |
| **B** | ONNX Runtime WebGPU | GPU 加速；不可用时自动回退 A |

运行时：**优先 WebGPU，失败则回退 CPU WASM**。页面也可手动切换后端。

> 说明：上游 ncnn 的浏览器 WebGPU 尚不成熟，因此路线 B 使用 [onnxruntime-web](https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html) WebGPU EP，与路线 A 共用同一套 UI。

English: see [README_EN.md](README_EN.md)

---

## 功能

- 浏览器本地推理（需较新的桌面 Chrome / Edge / Firefox）
- **自动扫描** `models/`：放入成对的 `.param` + `.bin`，重新编译后即可选择
- 分块（tile）推理 + 进度条
- WebGPU / CPU 后端切换；状态栏显示当前 WebGPU 适配器

## 仓库结构（精简）

```
├── main.cpp / realesrgan.* / shape_layer.*   # 路线 A C++ 推理
├── CMakeLists.txt / build.sh                 # Emscripten 构建 + 组装 dist/
├── local_server.go                           # 服务 dist/ 的本地静态服务器（含 COOP/COEP）
├── ncnn/ / emsdk/                            # Git 子模块
├── models/                                   # CPU ncnn 模型源（权重不进 Git，编译时打进 .data）
├── web/                                      # 网页源码与 WebGPU 生成资源（发布输入，不直接部署）
│   ├── index.html                            # 前端
│   ├── wasmFeatureDetect.js
│   ├── webgpu/realesrgan-webgpu.js           # 路线 B 引擎
│   ├── models-onnx/                          # WebGPU ONNX（.onnx 不进 Git）
│   └── ort/                                  # onnxruntime-web 静态资源（不进 Git）
├── dist/                                     # 构建产物：自包含站点（不进 Git，可直接部署）
│   ├── index.html
│   ├── statics/                              # 脚本、WASM、pthread worker、ORT
│   └── models/                               # manifest.json、ONNX、CPU .data
└── scripts/
    ├── download_models.sh                    # 下载默认小模型
    ├── prepare_webgpu_models.sh              # 导出 ONNX + 安装 ORT
    ├── convert_x2plus.sh                     # 转换 x2plus -> ncnn
    └── pytorch2onnx_*.py
```

**不会提交到 Git 的大文件**（由脚本生成）：模型权重、WASM `.data`、ONNX、`web/ort/`、`dist/`、`node_modules/`、`build/`。

---

## 环境要求

| 依赖 | 用途 | 备注 |
|------|------|------|
| Git | 克隆仓库 + 子模块 | 需能访问 GitHub |
| [Emscripten](https://emscripten.org/) 3.1.28+ | 编译路线 A | Linux / macOS 见下方安装示例 |
| CMake 3.10+ | 构建 | |
| Ninja（推荐） | 加快编译 | `pip install ninja` 即可 |
| Go 1.18+（可选） | `local_server.go` | 也可用 nginx 等能加 COOP/COEP 头的静态服务器 |
| Python 3.9+ + PyTorch（可选） | 仅准备 WebGPU ONNX / 转换 x2plus 时需要 | |
| Node.js 18+ / npm（可选） | 仅准备 WebGPU 时安装 onnxruntime-web | |
| curl 或 wget | 下载模型与 ORT 资源 | macOS 无需额外安装 `unzip` |
| 浏览器 | Chrome / Edge（WebGPU）或支持 WASM SIMD+pthread 的桌面浏览器 | **不支持 iOS** |

### 安装 Emscripten（Linux / macOS，首次构建前执行一次）

```bash
cd emsdk
./emsdk install 3.1.28
./emsdk activate 3.1.28
cd ..
```

`build.sh` 会自动加载 `emsdk/emsdk_env.sh`，无需在每个新终端手动 `source`。

---

## 快速开始（推荐流程）

在仓库根目录执行：

### 1. 克隆并拉取子模块

```bash
git clone --recursive https://github.com/panmeibing/real-esrgan-ncnn-webassembly.git
cd real-esrgan-ncnn-webassembly
```

若已克隆但未拉子模块：

```bash
git submodule update --init --recursive
```

### 2. 下载默认 CPU 小模型

```bash
./scripts/download_models.sh
```

默认包含：

- `realesr-general-x4v3`（照片 4x，约 4.6MB）
- `realesr-animevideov3-x2/x3/x4`（动漫）

可选：

- `./scripts/download_models.sh --include-wdn`

额外下载 wdn 变体。

> 大模型 `realesrgan-x2plus` **不要**直接下 HF 粗转包（可能含 `Shape` 层）。请用官方转换脚本（见下文「可选：x2plus」）。

### 3. 准备路线 B（WebGPU 发布资源）

首次构建 `dist/` 前，需要 Python + PyTorch + Node.js 生成 ONNX 和 ORT 资源：

```bash
./scripts/prepare_webgpu_models.sh
```

该脚本会：

1. 下载官方 `.pth`
2. 导出**固定尺寸** ONNX 到 `web/models-onnx/`
3. `npm install onnxruntime-web`，复制运行时到 `web/ort/`

导出的 WebGPU 模型：`realesr-animevideov3-x2/x3/x4`、`realesr-general-x4v3`、`realesrgan-x2plus`（约 67MB）、`realesrgan-x4plus`（约 67MB）、`realesrgan-x4plus-anime`（约 18MB）。`build.sh` 会把它们**全量**拷进 `dist/models/`，不需要的大模型请在生成后删掉再编译。

资源已生成时无需每次重复执行；`build.sh` 只负责校验并打包它们。

### 4. 编译路线 A 并组装发布站点

```bash
./build.sh
```

构建成功后会在项目根目录组装出自包含的发布目录 `dist/`：

```text
dist/
├── index.html
├── statics/v<内容哈希>/   # wasmFeatureDetect.js、webgpu/、ort/，以及 real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .worker.js
└── models/v<内容哈希>/    # manifest.json、*.onnx、real-esrgan-ncnn-webassembly-simd-threads.data
```

`statics/` 与 `models/` 下各有一个按内容哈希命名的子目录（`v…`），`index.html` 只引用这些带版本号的路径：**资源内容一变，URL 就变**，因此浏览器缓存和 CDN（Cloudflare 等）都不可能拿上一次构建的响应来回答新构建。这一点对 CPU 后端是硬要求——静态资源通常被缓存 30 天，而缺少 `Cross-Origin-Embedder-Policy` 的旧响应会让 Chrome 拦截 pthread worker，页面就会卡在「正在加载 CPU WASM 与模型资源…」。内容没变时哈希不变，缓存依旧有效。

`dist/` 可以脱离源码独立移动和部署。若缺少 ORT 或 ONNX 资源，脚本会在覆盖旧 `dist/` 之前直接报错并提示先运行准备脚本。

### 5. 启动本地服务器并打开页面

**必须**使用带 COOP/COEP 响应头的服务器，否则 WASM 多线程无法启用：

```bash
go run local_server.go   # 服务 ./dist，监听 0.0.0.0:8000
```

浏览器打开：**http://localhost:8000**。若改用 nginx 直接托管 `dist/`，则不需要 Go（见下文「部署到 nginx」）。

建议：

1. 等状态栏显示 WebGPU 或 CPU 就绪
2. 选一张**小图**（CPU 建议最长边 ≤ 512；WebGPU 可到约 1024）
3. 点「开始超分」，观察进度与结果

---

## 部署到 nginx

`dist/` 是自包含站点，可直接作为 nginx 的站点根目录，**不需要**再运行 Go 服务器：

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name example.com;

    ssl_certificate     /etc/nginx/ssl/example.pem;
    ssl_certificate_key /etc/nginx/ssl/example.key;

    root /var/www/real-esrgan;   # 指向 dist/ 的内容
    index index.html;

    # WASM 多线程（SharedArrayBuffer）必需，缺失时 CPU 后端无法启用多线程
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Embedder-Policy "require-corp" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;

    # 静态资源可长期缓存：URL 带内容哈希，新构建自然不会命中旧缓存。
    # 注意 nginx 的 add_header 是「替换」而非「继承」——location 里一旦出现
    # add_header，上面三个头就会全部丢失（Chrome 随即拦截同源 pthread worker，
    # 报 ERR_BLOCKED_BY_RESPONSE / coep-frame-resource-needs-coep-header）。
    # 所以这里用 expires（另一个模块），不要用 add_header Cache-Control。
    location /statics/ {
        expires 30d;
        try_files $uri =404;
    }

    location /models/ {
        expires 30d;
        try_files $uri =404;
    }

    # 入口 HTML 必须每次校验，否则拿不到新构建的资源路径。
    location = /index.html {
        expires -1;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
```

要点：

- 页面处于 `crossOriginIsolated` 状态是 CPU WASM pthread 的前提，三个响应头缺一不可，且必须覆盖 `/statics/`、`/models/` 等所有路径（worker 脚本尤其需要）。
- `.wasm` 需由 nginx 返回 `application/wasm`（默认 `mime.types` 一般已包含）；`.mjs` 必须返回 JavaScript（如 `application/javascript`），否则 ORT 的动态 `import()` 会被 MIME 校验拒绝。
- nginx 运行用户必须能读取 `dist/`。若放在用户家目录下，还要保证上级目录具备执行权限，否则会 403；更稳妥的做法是把内容复制到 `/var/www/` 下。
- 改完执行 `nginx -t && systemctl reload nginx`。

### 前置 Cloudflare 时的注意事项

- 静态资源会被 Cloudflare 边缘缓存；带内容哈希的 URL 天然绕过旧副本，但历史上被缓存的旧路径要等 TTL 或在后台 Purge Cache 才会消失。
- 建议关闭该站点的 **Rocket Loader**：它会自行抓取并 eval 脚本，使 `document.currentScript` 为空，容易破坏 Emscripten 这类依赖脚本路径的加载器（前端已通过 `mainScriptUrlOrBlob` 兜底，但关掉更稳）。
- 开页后可在控制台执行 `crossOriginIsolated` 自检，正常应为 `true`。

---

## 可选：转换 `realesrgan-x2plus`（CPU ncnn）

```bash
# 1) 下载官方权重到 _convert/RealESRGAN_x2plus.pth
# 2) 准备 onnx2ncnn / ncnnoptimize
#    脚本从 PATH 查找，也可通过 NCNN_ONNX2NCNN / NCNNOPTIMIZE 指定路径。
# 3) 运行：
./scripts/convert_x2plus.sh
# 4) 重新 ./build.sh
```

WebGPU 版 x2plus / x4plus / x4plus-anime 由 `prepare_webgpu_models.sh` 一并导出（x2plus、x4plus 各约 67MB，x4plus-anime 约 18MB）。

---

## 添加自己的模型

### CPU（路线 A）

1. 准备成对的 `name.param` + `name.bin`（ncnn 格式，建议输入/输出为 `data`/`output`）
2. 放入 `models/`（文件名带 `x2`/`x3`/`x4`/`x2plus` 便于识别倍率）
3. 重新运行 `./build.sh`
4. 刷新页面

详见 [`models/README.md`](models/README.md)。

### WebGPU（路线 B）

1. 导出固定输入尺寸 ONNX（与 tile 尺寸一致，见 `scripts/pytorch2onnx_webgpu.py`）
2. 放入 `web/models-onnx/`，更新 `manifest.json`
3. 重新运行 `./build.sh`（把 ONNX 打包进 `dist/models/`），刷新页面

---

## 常见问题

| 问题 | 处理 |
|------|------|
| pthread / SharedArrayBuffer 失败 | 必须用带 COOP/COEP 的服务（`local_server.go` 或 nginx）；不要用 `file://` |
| 切换「强制 CPU」后一直停在「正在加载 CPU WASM 与模型资源…」，控制台报 worker 被屏蔽 | 该资源响应缺少 COEP（常见于 CDN 边缘仍缓存着旧构建，或 nginx 的 `location` 里写了 `add_header` 覆盖掉三个隔离头）。前端已用内容哈希目录规避旧缓存；确认 `crossOriginIsolated === true`，必要时 Purge CDN 缓存 |
| `Emscripten is not installed` | 在 `emsdk/` 中执行 `./emsdk install 3.1.28 && ./emsdk activate 3.1.28` |
| WebGPU 提示找不到 `dist/statics/ort/ort.webgpu.min.js` | 运行 `./scripts/prepare_webgpu_models.sh`，再重新 `./build.sh` |
| 子模块为空 | `git submodule update --init --recursive` |
| WebGPU 报 Shape mismatch / buffer reuse | 使用本仓库脚本导出的**固定尺寸** ONNX，不要用错误共用 `height`/`width` 符号维的动态模型 |
| ORT 找不到 `.mjs` | 重新运行 `./scripts/prepare_webgpu_models.sh`，确保 `web/ort/` 含全部 `ort-wasm-simd-threaded.*`，再重新 `./build.sh` |
| 首次加载很慢 / 内存爆 | `models/` 里大模型会打进 `.data`；生产环境只保留小模型再编译 |
| 中国大陆拉 GitHub 失败 | 配置代理 / VPN 后再拉子模块与模型 |

---

## 致谢

- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
- [Tencent/ncnn](https://github.com/Tencent/ncnn)
- [hanFengSan/realcugan-ncnn-webassembly](https://github.com/hanFengSan/realcugan-ncnn-webassembly)
- [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime)

## License

本仓库代码以 [BSD 3-Clause](LICENSE) 发布。第三方组件与模型请遵守各自许可证，详见 [NOTICE](NOTICE)。

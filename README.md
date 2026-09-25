# Scaler

在浏览器中把照片和动漫图片放大 4 倍：[scaler.itools.top](https://scaler.itools.top/)。图片在本机处理，不上传也不存储。

底层算法与模型来自 [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)，源码仓库为 [seamile/realesrgan-wasm](https://github.com/seamile/realesrgan-wasm)。

| 路线 | 后端 | 说明 |
|------|------|------|
| **A** | ncnn 编译为 Emscripten WebAssembly（SIMD + pthread） | 兼容面广，兜底 |
| **B** | onnxruntime-web 的 WebGPU 执行提供程序 | GPU 加速 |

自动模式先尝试 WebGPU，在 WebGPU 不可用、初始化失败或处理失败时回退到 CPU；手动「强制 WebGPU / 强制 CPU」不会自动回退。

隐私：像素处理全部在浏览器内存中用本机 CPU/GPU 完成，本应用不上传或存储图片与结果，只有你点击下载时才会保存文件。页面仍会联网下载程序代码、运行时和所选模型。

> 说明：上游 ncnn 的浏览器 WebGPU 尚不成熟，因此路线 B 使用 [onnxruntime-web](https://onnxruntime.ai/docs/tutorials/web/ep-webgpu.html) WebGPU EP，与路线 A 共用同一套 UI。

English: see [README_EN.md](README_EN.md)

---

## 功能

- 浏览器本地推理（需较新的桌面 Chrome / Edge / Firefox；**不支持 iOS**）
- 界面固定提供四个 4× 模型，按「图片风格 × 处理偏好」自动匹配：

  | 图片风格 | 速度优先 | 质量优先 |
  |----------|----------|----------|
  | 真实照片 | `realesr-general-x4v3` | `realesrgan-x4plus` |
  | 动漫图片 | `realesr-animevideov3-x4` | `realesrgan-x4plus-anime` |

  CPU 与 WebGPU 使用同名模型；新增模型需要改代码，见「添加自己的模型」。
- 输入 PNG / JPEG / WebP / BMP，结果下载为 PNG
- 分块（tile）推理 + 进度条
- WebGPU / CPU 后端切换；状态栏显示当前 WebGPU 适配器
- 11 种界面语言（构建时预渲染成静态入口）

## 仓库结构（精简）

```
├── main.cpp / realesrgan.* / shape_layer.*   # 路线 A C++ 推理
├── CMakeLists.txt / build.sh                 # Emscripten 构建 + 组装 dist/
├── local_server.go                           # 服务 dist/ 的本地静态服务器（含 COOP/COEP）
├── ncnn/ / emsdk/                            # Git 子模块
├── models/                                   # CPU ncnn 模型源（权重不进 Git，构建时发布到 dist/）
├── web/                                      # 网页源码与 WebGPU 生成资源（发布输入，不直接部署）
│   ├── index.html                            # 前端（内联多语言表）
│   ├── i18n.js                               # 其余 9 种语言文案，构建时内联进 index.html
│   ├── wasmFeatureDetect.js
│   ├── webgpu/realesrgan-webgpu.js           # 路线 B 引擎
│   ├── img/sample-*.webp                     # 首页效果展示图
│   ├── robots.txt / sitemap.xml
│   ├── models-onnx/                          # WebGPU ONNX（.onnx 不进 Git）
│   └── ort/                                  # onnxruntime-web 静态资源（不进 Git）
├── dist/                                     # 构建产物：自包含站点（不进 Git，可直接部署）
│   ├── index.html
│   ├── statics/                              # 脚本、WASM、pthread worker、ORT
│   └── models/                               # manifest.json、ONNX、CPU *.param/*.bin（按需下载）
└── scripts/
    ├── prepare_models.sh                     # 一次备齐四个生产模型与 ORT（= download_models.sh + prepare_webgpu_models.sh --skip-x2plus）
    ├── download_models.sh                    # 下载四个 CPU ncnn 模型（--include-wdn 额外下载 wdn 变体）
    ├── prepare_webgpu_models.sh              # 导出 ONNX + 安装 ORT（--skip-x2plus 与 CPU 侧对齐）
    ├── check_web_ui.mjs                      # 校验多语言文案与页面结构（构建前自检）
    ├── prerender_locales.mjs                 # 生成各语言的预渲染入口
    ├── build_ncnn_tools.sh                   # 本机编译 onnx2ncnn / ncnnoptimize（仅转换 x2plus 时需要）
    ├── convert_x2plus.sh                     # 转换 x2plus -> ncnn
    └── pytorch2onnx_*.py
```

**不会提交到 Git 的大文件**（由脚本生成）：模型权重、ONNX、`web/ort/`、`dist/`、`node_modules/`、`build/`。

---

## 环境要求

### 必需（克隆 + 编译路线 A + 组装 `dist/`）

| 依赖 | 用途 | 说明 |
|------|------|------|
| Git | 克隆仓库与 `ncnn/`、`emsdk/` 子模块 | 需能访问 GitHub |
| sh / bash + coreutils | 运行 `build.sh` 与 `scripts/*.sh` | Linux / macOS 自带 |
| CMake 3.10+ | 配置并驱动构建 | 实测 4.4.3；`build.sh` 用默认生成器，**不要求 Ninja** |
| C/C++ 工具链 | Emscripten 编译底座、本机编译 `onnx2ncnn` | macOS 装 Xcode Command Line Tools；Linux 用 gcc / clang |
| [Emscripten](https://emscripten.org/) **3.1.28** | 编译路线 A | 由 `emsdk/` 子模块安装，见下方示例；`build.sh` 会自动 `emsdk_env.sh` |
| curl 或 wget | 下载模型与 ORT 资源 | 二选一，脚本自动探测 |
| `sha256sum` / `shasum` / `openssl` | `build.sh` 计算内容哈希目录名 | 有其一即可；macOS 自带 `shasum` |
| Python 3.9+（`$PYTHON`，默认 `python3`） | `download_models.sh` 解压官方 ncnn 包 | 脚本启动时会校验解释器存在；解压优先用 `unzip`，没有 `unzip` 时用 Python `zipfile` |
| 浏览器 | 打开页面 | Chrome / Edge（WebGPU），或支持 WASM SIMD + pthread 的桌面浏览器；**不支持 iOS** |

### 按需安装（用到相应脚本时才需要）

| 依赖 | 何时需要 | 安装 |
|------|----------|------|
| Python 3.9+ + PyTorch + onnx | `prepare_webgpu_models.sh`（导出 ONNX）、`convert_x2plus.sh`（转换 x2plus） | 见下方「Python 环境」 |
| Node.js 18+ / npm | `prepare_webgpu_models.sh` 下载 onnxruntime-web 到 `web/ort/` | 能用 `npm -v` 即可 |
| `protoc` + libprotobuf + C++17 编译器 | `build_ncnn_tools.sh` 编译 `onnx2ncnn`（上游 ncnn 已不再默认编译它）；仅在需要 CPU 版 x2plus 时使用 | macOS `brew install protobuf`；Debian/Ubuntu `apt install protobuf-compiler libprotobuf-dev`。有 `pkg-config` 最好，没有则回退到 `brew --prefix protobuf` |
| Go 1.18+ | 用 `local_server.go` 本地预览 `dist/` | 也可改用 nginx（见下文），此时不需要 Go |

`build.sh` 的并行度写死为 `-j4`，机器更强可自行修改。

### Python 环境（准备路线 B / 转换 x2plus 时）

三个脚本都用 `$PYTHON` 指定解释器（默认 `python3`），建议单独建虚拟环境：

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install torch onnx                  # torch 用 CPU 版即可
export PYTHON="$PWD/.venv/bin/python"   # 后续脚本都会用它
```

自检：

```bash
"$PYTHON" -c 'import torch, onnx; print(torch.__version__, onnx.__version__)'
```

- `torch` 只用于导出，不需要 GPU / CUDA；`onnx` 是 `torch.onnx.export` 的运行时依赖。
- 导出脚本用 `inspect` 探测 `torch.onnx.export` 是否有 `dynamo` 参数：老版本 torch 直接用默认（经典）导出器，torch ≥ 2.9 会显式传 `dynamo=False`。`onnx2ncnn` 只认经典导出器的图，这一步决定了转换能否成功。
- 本仓库验证过的组合：macOS（x86_64）+ Emscripten 3.1.28、CMake 4.4.3、Node 24、Go 1.27、protobuf 36.1、Python 3.14 + torch 2.14 + onnx 1.23。

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
git clone --recursive https://github.com/seamile/realesrgan-wasm.git
cd realesrgan-wasm
```

若已克隆但未拉子模块：

```bash
git submodule update --init --recursive
```

### 2. 下载 CPU 模型

```bash
./scripts/download_models.sh
```

> 如果接下来会执行步骤 3，这一步可以跳过：`prepare_models.sh` 内部已经调用了 `download_models.sh`。单独执行本步骤只适合「只用 CPU 路线」的场景。

默认下载四个生产 CPU 模型（约 47MB），与 WebGPU 清单（`web/models-onnx/manifest.json`）保持一致：

- `realesr-general-x4v3`（照片 4x，约 4.6MB）
- `realesr-animevideov3-x4`（动漫 4x，约 1.2MB）
- `realesrgan-x4plus`（照片 4x，约 33MB）
- `realesrgan-x4plus-anime`（动漫 4x，6B 版，约 9MB）

可选：

- `./scripts/download_models.sh --include-wdn` 额外下载 wdn 变体（仅供自用，WebGPU 侧没有对应模型）。

> CPU 模型不再打进 `.data`：页面在点击放大后才下载当前选中的 `.param` + `.bin`，并写入 Emscripten 内存文件系统。生产环境只需发布本目录中的四个生产模型。
> `realesrgan-x2plus` 没有官方 ncnn 包，需要自行转换（见下文「可选：转换 realesrgan-x2plus」），**不要**直接用第三方 HF 粗转包（可能含 `Shape` 层）。

### 3. 准备模型与 WebGPU 资源

首次构建 `dist/` 前，需要 Python + PyTorch + onnx + Node.js 生成 CPU 与 WebGPU 资源（依赖说明见「环境要求」）：

```bash
./scripts/prepare_models.sh
```

该脚本会：

1. 下载官方 ncnn / `.pth` 资源
2. 导出**固定尺寸** ONNX 到 `web/models-onnx/`
3. 把 CPU 与 WebGPU 清单都收敛到四个生产模型：`realesr-general-x4v3`、`realesr-animevideov3-x4`、`realesrgan-x4plus`（约 67MB）、`realesrgan-x4plus-anime`（约 18MB）
4. `npm install onnxruntime-web`，复制运行时到 `web/ort/`

`build.sh` 会把 manifest 列出的 ONNX 与 `models/` 中的四个 CPU `.param`/`.bin` 拷进 `dist/models/`，运行时按选择只下载其中一个模型。

资源已生成时无需每次重复执行；`build.sh` 只负责校验（manifest 中列出的每个 `.onnx`、四个 CPU 模型必须存在）并打包它们。

### 4. 编译路线 A 并组装发布站点

```bash
./build.sh
```

构建成功后会在项目根目录组装出自包含的发布目录 `dist/`：

```text
dist/
├── index.html             # 根入口（静态正文为英语，运行时按浏览器语言切换）
├── <locale>/index.html    # en zh-Hans zh-Hant fr de es pt ar ru ja ko：预渲染的本地化入口
├── LICENSE / NOTICE / robots.txt / sitemap.xml
├── statics/v<内容哈希>/   # wasmFeatureDetect.js、webgpu/、ort/、img/（首页效果图），以及 real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .worker.js
└── models/v<内容哈希>/    # manifest.json、*.onnx、CPU *.param/*.bin（按需下载）
```

每个语言入口都由 `scripts/prerender_locales.mjs` 在构建时烘焙好 `<html lang>`、`<title>`、描述、canonical/hreflang、Open Graph、JSON-LD 与静态正文；正文另有一份内联的多语言表，供运行时切换语言使用（页面不再单独请求 `i18n.js`）。

`statics/` 与 `models/` 下各有一个按内容哈希命名的子目录（`v…`），`index.html` 只引用这些带版本号的路径：**资源内容一变，URL 就变**，因此浏览器缓存和 CDN（Cloudflare 等）都不可能拿上一次构建的响应来回答新构建。这一点对 CPU 后端是硬要求——静态资源通常被缓存 30 天，而缺少 `Cross-Origin-Embedder-Policy` 的旧响应会让 Chrome 拦截 pthread worker，页面就会卡在「正在加载 CPU 引擎…」。内容没变时哈希不变，缓存依旧有效。

`dist/` 可以脱离源码独立移动和部署。若缺少 ORT 或 ONNX 资源，脚本会在覆盖旧 `dist/` 之前直接报错并提示先运行准备脚本。

### 5. 启动本地服务器并打开页面

**必须**使用带 COOP/COEP 响应头的服务器，否则 WASM 多线程无法启用：

```bash
go run ./local_server.go   # 只服务 ./dist，监听 0.0.0.0:8000，并设置 COOP/COEP/CORP
```

浏览器打开：**http://localhost:8000**。不要用 `file://` 或不设置这些响应头的普通静态服务器，否则 CPU pthread 后端不可用。若改用 nginx 直接托管 `dist/`，则不需要 Go（见下文「部署到 nginx」）。

支持的输入格式为 PNG / JPEG / WebP / BMP，结果一律下载为 PNG。建议：

1. 等状态栏显示 WebGPU 或 CPU 就绪
2. 选一张**小图**：CPU 建议最长边 ≤ 512px，WebGPU 可到 1024px
3. 点「放大到 4 倍」，观察进度与结果

尺寸只是建议而非硬性限制：超过约 400 万像素时页面会提示图片较大，处理可能很慢，甚至耗尽内存。

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

> **当前发布版只支持上面四个 4× 模型。** 本节脚本保留作开发用途：转换出的 `realesrgan-x2plus` **不会**自动出现在站点里——`build.sh` 只复制并校验那四个模型，前端模型映射也只认四个 4× 模型。要真正启用它，需要同时修改 `web/index.html` 的模型映射与输出倍率、`build.sh` 的复制/校验列表。

`realesrgan-x2plus`（x2）官方只发布了 `.pth`，没有 ncnn 包，需要在本机转换一次；想让它两个后端都可用，CPU 侧按本节转换，GPU 侧准备资源时去掉 `--skip-x2plus` 并同步 `web/models-onnx/manifest.json`。

```bash
# 1) 准备主机端工具（只需一次；需要 cmake / protoc / C++ 工具链）
./scripts/build_ncnn_tools.sh
#    产物落在 _convert/ncnn-build/tools/，convert_x2plus.sh 会自动找到；
#    也可以放到 PATH，或用 NCNN_ONNX2NCNN / NCNNOPTIMIZE 指定路径。

# 2) 准备官方权重 _convert/RealESRGAN_x2plus.pth
#    跑过不带 --skip-x2plus 的 prepare_webgpu_models.sh 就已经有了；
#    否则从 Real-ESRGAN v0.2.1 的 release 下载 RealESRGAN_x2plus.pth 放到 _convert/。

# 3) 转换并安装到 models/
./scripts/convert_x2plus.sh

# 4) 重新组装发布站点
./build.sh
```

`convert_x2plus.sh` 会依次执行导出 ONNX（`pytorch2onnx_x2plus.py`）、`onnx2ncnn`、`ncnnoptimize`（fp16），再把输入 blob 改名为 `data`、确认没有残留 `Shape` 层，最后写入 `models/realesrgan-x2plus.param`（约 0.2MB）与 `.bin`（约 33MB）。

不想保留时：删掉这两个文件，再用 `./scripts/prepare_webgpu_models.sh --skip-x2plus` 重跑一次（会同步清掉 manifest 里的 x2plus），然后重新 `./build.sh`。

> 上游 ncnn 已不再默认编译 `onnx2ncnn`（子模块的 `tools/CMakeLists.txt` 去掉了 `add_subdirectory(onnx)`），所以 `build_ncnn_tools.sh` 是单独对着 protobuf 编译 `ncnn/tools/onnx/onnx2ncnn.cpp` 的。

---

## 添加自己的模型

界面上的模型是固定的四个 4× 选择，新增模型需要同时改代码，**不能只把文件放进目录**。

### CPU（路线 A）

1. 准备成对的 `name.param` + `name.bin`（ncnn 格式，建议输入/输出为 `data`/`output`）
2. 放入 `models/`（文件名带 `x2`/`x3`/`x4`/`x2plus` 便于识别倍率）
3. 在 `build.sh` 的 CPU 模型列表（**复制与校验两处**）中加入 `name`
4. 重新运行 `./build.sh`，刷新页面

### WebGPU（路线 B）

1. 导出固定输入尺寸 ONNX（与 tile 尺寸一致，见 `scripts/pytorch2onnx_webgpu.py`）
2. 放入 `web/models-onnx/`，更新 `manifest.json`
3. 重新运行 `./build.sh`（把 ONNX 打包进 `dist/models/`），刷新页面

### 前端映射

在 `web/index.html` 的模型映射中把新模型接上去，否则用户选不到它：

```js
map={photo:{speed:'…',quality:'…'},anime:{speed:'…',quality:'…'}}
```

倍率不是 4× 时，还要同步输出尺寸与下载逻辑（当前结果画布按 4× 分配）。

详见 [`models/README.md`](models/README.md)。

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 图片会不会被上传 | 不会。像素处理全部在浏览器内存中用本机 CPU/GPU 完成，本应用不上传或存储图片与结果；只有你点击下载时结果才会保存。页面仍会联网下载程序代码、运行时和所选模型 |
| 支持哪些格式？图片可以多大 | 输入 PNG / JPEG / WebP / BMP，结果下载为 PNG；建议最长边 CPU ≤ 512px、WebGPU ≤ 1024px（建议而非硬性限制，超大图会很慢甚至耗尽内存） |
| 可以商用吗 | 本仓库代码为 BSD 3-Clause，允许商用；第三方组件与模型遵循各自许可证，见 [NOTICE](NOTICE) |
| pthread / SharedArrayBuffer 失败 | 必须用带 COOP/COEP 的服务（`local_server.go` 或 nginx）；不要用 `file://` |
| 切换「强制 CPU」后一直停在「正在加载 CPU 引擎…」，控制台报 worker 被屏蔽 | 该资源响应缺少 COEP（常见于 CDN 边缘仍缓存着旧构建，或 nginx 的 `location` 里写了 `add_header` 覆盖掉三个隔离头）。前端已用内容哈希目录规避旧缓存；确认 `crossOriginIsolated === true`，必要时 Purge CDN 缓存 |
| `Emscripten is not installed` | 在 `emsdk/` 中执行 `./emsdk install 3.1.28 && ./emsdk activate 3.1.28` |
| WebGPU 提示找不到 `dist/statics/v<内容哈希>/ort/ort.webgpu.min.js` | 运行 `./scripts/prepare_webgpu_models.sh`，再重新 `./build.sh` |
| 子模块为空 | `git submodule update --init --recursive` |
| `Unable to find onnx2ncnn` / `ncnnoptimize` | 先运行 `./scripts/build_ncnn_tools.sh`（需要 `protoc` 与 C++ 工具链），产物会自动落到 `_convert/ncnn-build/tools/` |
| CPU 与 WebGPU 的模型列表不一致 | 运行 `./scripts/prepare_models.sh` 把两侧清单统一收敛到四个生产模型；可选模型按需同时补到 CPU 与 ONNX 侧 |
| WebGPU 报 Shape mismatch / buffer reuse | 使用本仓库脚本导出的**固定尺寸** ONNX，不要用错误共用 `height`/`width` 符号维的动态模型 |
| 构建报缺少 ORT 资源 | `build.sh` 要求 `web/ort/` 中存在 `ort.webgpu.min.js`、`ort-wasm-simd-threaded.asyncify.mjs`、`ort-wasm-simd-threaded.asyncify.wasm`；缺哪个就重新运行 `./scripts/prepare_webgpu_models.sh` |
| 首次加载很慢 / 内存爆 | CPU 只下载当前选中的 `.param` + `.bin`；WebGPU 在首次使用某个模型时下载对应 `.onnx`。若发布目录混入非生产模型，可在构建前清理 `models/` 与 `web/models-onnx/` |
| 中国大陆拉 GitHub 失败 | 配置代理 / VPN 后再拉子模块与模型 |

---

## 致谢

本项目站在这些开源工作之上：

- [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) — 模型与算法
- [panmeibing/real-esrgan-ncnn-webassembly](https://github.com/panmeibing/real-esrgan-ncnn-webassembly) — 本项目的 WebAssembly 实现基础
- [hanFengSan/realcugan-ncnn-webassembly](https://github.com/hanFengSan/realcugan-ncnn-webassembly) — Emscripten + ncnn 浏览器工程参考
- [Tencent/ncnn](https://github.com/Tencent/ncnn) — CPU 推理框架
- [Microsoft ONNX Runtime](https://github.com/microsoft/onnxruntime) — WebGPU 执行提供程序

## License

本仓库代码以 [BSD 3-Clause](LICENSE) 发布。第三方组件与模型请遵守各自许可证，详见 [NOTICE](NOTICE)。

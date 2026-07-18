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
- WebGPU / CPU 后端切换；Windows 双显卡可提示核显问题

## 仓库结构（精简）

```
├── main.cpp / realesrgan.* / shape_layer.*   # 路线 A C++ 推理
├── CMakeLists.txt / build.ps1 / build.sh     # Emscripten 构建
├── local_server.go                           # 带 COOP/COEP 的本地静态服务器
├── ncnn/                                     # Git 子模块
├── models/                                   # CPU ncnn 模型（权重不进 Git）
├── web/
│   ├── index.html                            # 前端
│   ├── wasmFeatureDetect.js
│   ├── webgpu/realesrgan-webgpu.js           # 路线 B 引擎
│   ├── models-onnx/                          # WebGPU ONNX（.onnx 不进 Git）
│   └── ort/                                  # onnxruntime-web 静态资源（不进 Git）
└── scripts/
    ├── download_models.ps1                   # 下载默认小模型
    ├── prepare_webgpu_models.ps1             # 导出 ONNX + 安装 ORT
    ├── convert_x2plus.ps1                    # 官方流程转换 x2plus -> ncnn
    └── pytorch2onnx_*.py
```

**不会提交到 Git 的大文件**（由脚本生成）：模型权重、WASM `.data`、ONNX、`web/ort/`、`node_modules/`、`build/`。

---

## 环境要求

| 依赖 | 用途 | 备注 |
|------|------|------|
| Git | 克隆仓库 + 子模块 | 需能访问 GitHub |
| [Emscripten](https://emscripten.org/) 3.1.28+ | 编译路线 A | Windows 见下方安装示例 |
| CMake 3.10+ | 构建 | |
| Ninja（推荐） | 加快编译 | `pip install ninja` 即可 |
| Go 1.18+（可选） | `local_server.go` | 也可用其它能加 COOP/COEP 头的静态服务器 |
| Python 3.9+ + PyTorch（可选） | 仅准备 WebGPU ONNX / 转换 x2plus 时需要 | |
| Node.js 18+ / npm（可选） | 仅准备 WebGPU 时安装 onnxruntime-web | |
| 浏览器 | Chrome / Edge（WebGPU）或支持 WASM SIMD+pthread 的桌面浏览器 | **不支持 iOS** |

### Windows 安装 Emscripten

```powershell
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
.\emsdk install 3.1.28
.\emsdk activate 3.1.28
.\emsdk_env.ps1   # 每个新终端都要执行一次，或写入配置文件
```

确认：

```powershell
emcc -v
echo $env:EMSDK
```

---

## 快速开始（推荐流程）

在仓库根目录执行：

### 1. 克隆并拉取子模块

```powershell
git clone --recursive https://github.com/panmeibing/real-esrgan-ncnn-webassembly.git
cd real-esrgan-ncnn-webassembly
```

若已克隆但未拉子模块：

```powershell
git submodule update --init --recursive
```

### 2. 下载默认 CPU 小模型

```powershell
powershell -File .\scripts\download_models.ps1
```

默认包含：

- `realesr-general-x4v3`（照片 4x，约 4.6MB）
- `realesr-animevideov3-x2/x3/x4`（动漫）

可选：`powershell -File .\scripts\download_models.ps1 -IncludeWdn` 额外下载 wdn 变体。

> 大模型 `realesrgan-x2plus` **不要**直接下 HF 粗转包（可能含 `Shape` 层）。请用官方转换脚本（见下文「可选：x2plus」）。

### 3. 编译路线 A（CPU WASM）

先激活 emsdk，再：

```powershell
powershell -File .\build.ps1
```

成功后 `web/` 下会出现：

- `real-esrgan-ncnn-webassembly-simd-threads.js / .wasm / .data / .worker.js`

Linux / macOS：

```bash
source /path/to/emsdk/emsdk_env.sh
sh build.sh
```

### 4.（可选）准备路线 B（WebGPU）

需要 Python + PyTorch + Node.js：

```powershell
powershell -File .\scripts\prepare_webgpu_models.ps1
```

会：

1. 下载官方 `.pth`
2. 导出**固定尺寸** ONNX 到 `web/models-onnx/`
3. `npm install onnxruntime-web`，复制运行时到 `web/ort/`

无 GPU 也可跳过本步；页面会自动走 CPU。

### 5. 启动本地服务器并打开页面

**必须**使用带 COOP/COEP 响应头的服务器，否则 WASM 多线程无法启用：

```powershell
go run local_server.go
```

浏览器打开：**http://localhost:8000**

建议：

1. 等状态栏显示 WebGPU 或 CPU 就绪
2. 选一张**小图**（CPU 建议最长边 ≤ 512；WebGPU 可到约 1024）
3. 点「开始超分」，观察进度与结果

---

## Windows 双显卡（核显 vs 独显）

Chrome 在 Windows 上常把 WebGPU 绑在**核显**，并**忽略** `powerPreference`（见 [crbug 369219127](https://crbug.com/369219127)）。核显上 WebGPU 可能比 CPU 还慢。

强制使用独显（改完后完全退出并重启 Chrome）：

1. 打开 `chrome://flags/#force-high-performance-gpu` -> **Enabled** -> Relaunch
2. 或：系统设置 -> 显示 -> 图形 -> 为 `chrome.exe` 选择「高性能」
3. 或：NVIDIA 控制面板 -> 程序设置 -> Chrome -> 高性能 NVIDIA 处理器

页面状态栏会显示当前 WebGPU 适配器名称，便于确认。

---

## 可选：转换 `realesrgan-x2plus`（CPU ncnn）

```powershell
# 1) 下载官方权重到 _convert/RealESRGAN_x2plus.pth
# 2) 准备 onnx2ncnn / ncnnoptimize（见 scripts/convert_x2plus.ps1 注释）
# 3) 运行：
powershell -File .\scripts\convert_x2plus.ps1
# 4) 重新 build.ps1
```

WebGPU 版 x2plus 由 `prepare_webgpu_models.ps1` 一并导出（ONNX 约 67MB）。

---

## 添加自己的模型

### CPU（路线 A）

1. 准备成对的 `name.param` + `name.bin`（ncnn 格式，建议输入/输出为 `data`/`output`）
2. 放入 `models/`（文件名带 `x2`/`x3`/`x4`/`x2plus` 便于识别倍率）
3. 重新 `build.ps1`
4. 刷新页面

详见 [`models/README.md`](models/README.md)。

### WebGPU（路线 B）

1. 导出固定输入尺寸 ONNX（与 tile 尺寸一致，见 `scripts/pytorch2onnx_webgpu.py`）
2. 放入 `web/models-onnx/`，更新 `manifest.json`
3. 刷新页面（无需重编 WASM）

---

## 常见问题

| 问题 | 处理 |
|------|------|
| pthread / SharedArrayBuffer 失败 | 必须用 `local_server.go`（或自建 COOP/COEP）；不要用 `file://` |
| `EMSDK is not set` | 执行 `emsdk_env.ps1` / `source emsdk_env.sh` |
| 子模块为空 | `git submodule update --init --recursive` |
| WebGPU 报 Shape mismatch / buffer reuse | 使用本仓库脚本导出的**固定尺寸** ONNX，不要用错误共用 `height`/`width` 符号维的动态模型 |
| ORT 找不到 `.mjs` | 重新运行 `prepare_webgpu_models.ps1`，确保 `web/ort/` 含全部 `ort-wasm-simd-threaded.*` |
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


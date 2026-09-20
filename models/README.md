# models/ — CPU 模型目录（路线 A）

编译时，本目录下所有文件会通过 Emscripten `--preload-file` 打进 `.data`。

运行时会自动扫描：

- 每个 `*.param` 若存在同名 `*.bin`，即视为一个可用模型
- 从文件名猜测倍率（`x2` / `x3` / `x4` / `x2plus` 等）
- 从 `.param` 解析输入/输出 blob（兼容 `data` / `input`）

权重文件 **不提交到 Git**，请用脚本下载或自行放入。

## 一键下载（推荐）

Windows PowerShell：

```powershell
powershell -File .\scripts\download_models.ps1
# 可选 wdn 变体：
powershell -File .\scripts\download_models.ps1 -IncludeWdn
```

Linux：

```bash
./scripts/download_models.sh
# 可选 wdn 变体：
./scripts/download_models.sh --include-wdn
```

然后重新编译：

```powershell
powershell -File .\build.ps1
```

## 手动添加模型

```
models/
  realesr-general-x4v3.param
  realesr-general-x4v3.bin
```

刷新页面后下拉框会出现新模型。

## 推荐来源

| 模型 | 倍率 | 大小 | 说明 |
|------|------|------|------|
| realesr-animevideov3-x2/x3/x4 | 2/3/4 | ~1.2MB | 官方 ncnn-vulkan 包 |
| realesr-general-x4v3 | 4 | ~4.6MB | additional-models |
| realesrgan-x2plus | 2 | ~33MB fp16 | 用 `scripts/convert_x2plus.ps1` 或 `.sh` 官方流程转换，勿用含 Shape 的粗转包 |

## 注意

- **生产环境**只放小模型，否则首次加载 `.data` 很大
- 文件名尽量带倍率标记
- 优先使用官方/优化过的 ncnn 模型（`data`/`output`）
- 本项目保留自定义 `Shape` 层，仅作粗转模型兼容兜底

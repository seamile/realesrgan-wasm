# models-optional/

可选模型的**暂存目录**。程序**只扫描** `../models/`。

要把某个模型编进 WASM：把成对的 `.param` + `.bin` 复制到 `models/`，再执行 `./build.sh`。

本目录中的权重默认被 `.gitignore` 忽略。

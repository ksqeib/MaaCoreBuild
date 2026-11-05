# MaaCore Standalone 依赖引用总结

本文只回答一个问题：`include/upstream` / `include/3rd` / `resource` 在独立仓库里到底有没有被用到。

## 结论（面向只产出 `MaaCore.dll` + `MaaCore.pdb`）

- `include/upstream`：**编译期必需**。
- `include/3rd`：**编译期必需**。
- `resource`：**不是编译期必需**，本仓库默认目标不要求功能验证。

## 1) `include` 是否有用

有用，而且是必需。

关键引用：

- `AsstCaller.cpp` 第 1 行：`#include "AsstCaller.h"`
- `AsstCallerExtra.cpp` 第 1 行：`#include "AsstCallerExtra.h"`
- 这两个头由本仓库 `include/upstream/` 直接提供并跟踪。

构建层面：

- `CMakeLists.txt` 通过 `target_include_directories(MaaCore PUBLIC ${MAA_PUBLIC_INCLUDE_DIR} PRIVATE .)` 注入头文件搜索路径。
- `CMakeLists.txt` 通过 `file(GLOB_RECURSE MaaCore_PUBLIC_HEADERS ${MAA_PUBLIC_INCLUDE_DIR}/*.h)` 收集并安装公开头。

因此，缺少 `include` 时会直接影响 `MaaCore` 编译和对外 API 头导出。

## 2) `3rdparty/include` 是否有用

有用，而且是必需。

关键引用：

- `Task/Infrast/InfrastProductionTask.cpp` 第 8 行：`#include <calculator/calculator.hpp>`
- `Controller/AdbController.cpp` 第 14 行：`#include <zlib/decompress.hpp>`
- `Controller/Controller.cpp` 第 17 行：`#include <zlib/decompress.hpp>`

这些头来自 `include/3rd/calculator` 与 `include/3rd/zlib`。

因此，缺少 `include/3rd` 会在编译阶段报头文件找不到。

## 3) `resource` 是否有用

有用，但性质不同：

- 对“生成 `MaaCore.dll` / `MaaCore.pdb`”来说，`resource` **可缺省**。
- 本仓库工作流默认不做运行功能验证，因此不把 `resource` 作为构建前置条件。

关键引用：

- `AsstCaller.cpp` 第 55-68 行：`AsstLoadResource` 会把 `<path>/resource` 交给 `ResourceLoader::load(...)`。
- `AsstCaller.cpp` 第 75-88 行：`AsstCreate/AsstCreateEx` 会检查 `ResourceLoader` 是否已加载成功，未加载返回 `nullptr`。
- `Config/ResourceLoader.cpp` 第 145 行后：会加载 `onnx`、`PaddleOCR`、`tasks`、`tile` 等资源。

因此，`resource` 对“编译产物”不硬性，对“可运行能力”是硬依赖。

## 4) 对独立仓库维护的建议

若目标严格是“只编译产物”：

- 必保留并跟踪：`include/upstream`、`include/3rd`、`MaaUtils/`（源码）。
- 二进制依赖通过 `deps/` 提供：构建期 FastDeploy 小包由 `tools/fastdeploy-manifest.json` 锚定，其余依赖由 `tools/deps-versions.json` 和 `tools/build-upstream-deps.ps1` 从上游官方发布物组装；客户端运行库由 `tools/runtime-manifest.json` 锚定。
- `resource` 非编译依赖，不纳入默认构建流程。

这也是当前脚本和 `CMakeLists.txt` 以“仅产出 DLL/PDB”为目标进行精简的原因。


# MaaCoreBuild

MaaCore 的独立构建/发布仓库。

本仓库不保存 MaaCore 源码，只保存：

- `overlay/CMakeLists.txt`：把上游 MaaCore 改造成独立构建的 CMake 入口
- `include/upstream`、`include/3rd`：MaaCore 需要的头文件
- `cmake/`、`tools/`：依赖组装、构建、打包脚本
- `scripts/prepare-source.ps1`：拉取上游代码、MaaUtils 和 overlay
- `.github/workflows/nightly.yml`：每日 nightly 构建与发布

MaaUtils 不在本仓库内嵌，由 `tools/deps-versions.json` 固定到上游 `MaaXYZ/MaaUtils` 的 ref 或 commit，`prepare-source.ps1` 拉取后直接注入 `MAADEPS_DIR` / `MAA_DEPS_CONFIG` 适配。这样既不会漂移，也能在需要时显式升级。

## 工作方式

上游源码来自 `ksqeib/MaaCore` 的 `upstream-sync` 分支（由 MaaCore 仓库的同步 action 维护），不直接修改上游源码。

构建时：

1. `prepare-source.ps1` 克隆 `upstream-sync`
2. 用 `overlay/CMakeLists.txt` 覆盖上游 `CMakeLists.txt`
3. 注入 `MaaUtils/`、`include/`、`cmake/`、`tools/`
4. 在 `.work/MaaCore` 中执行 bootstrap / build / package

## MaaUtils

MaaUtils 是 MAA 的通用工具库，不是游戏逻辑，主要包含：

- 日志（Logger / LoggerUtils）
- UTF-8/UTF-16 编码转换（Encoding）
- 图像读写（ImageIo）
- IOStream / 子进程管道 / Socket（ADB、Controller 使用）
- 平台、Runtime、Port、Conf 等基础封装
- GPU 设备选择（GpuOption）
- UUID、Buffer、Singleton、ScopeLeave 等通用工具
- meojson 头文件

MaaCore 会大量 include `MaaUtils/...` 并链接 `MaaUtils.dll`。

本仓库**不再 vendored MaaUtils 源码**，而是：

- `tools/deps-versions.json` 固定 `MaaXYZ/MaaUtils` 的 repo + ref（当前 `master`）
- `scripts/prepare-source.ps1` 拉取该 ref 的最新 commit
- 直接在 `MaaUtils.cmake` 中注入 `MAADEPS_DIR` / `MAA_DEPS_CONFIG` 适配（不依赖 patch 文件的换行符）

## 本地构建

```powershell
powershell -File .\scripts\prepare-source.ps1

Set-Location .\.work\MaaCore
powershell -File .\tools\bootstrap-standalone.ps1
powershell -File .\tools\build-maacore-only.ps1 -SkipBootstrap -UseSccache -NoFresh -Version nightly
powershell -File .\tools\package-sdk.ps1 -Version nightly -OutputDir D:\self\maa\MaaCoreBuild\dist
```

`bootstrap` 默认 `-ReleaseOnly`：只编 Release 版 Boost.Regex / zlib，nightly 不需要 Debug 依赖。需要 Debug 构建时：

```powershell
powershell -File .\tools\bootstrap-standalone.ps1 -ReleaseOnly:$false
```

## Nightly

`.github/workflows/nightly.yml`：

- 每天 18:00 UTC 自动运行，也支持手动触发
- 运行前先比较：
  - `MaaCore:upstream-sync` 最新 commit
  - `MaaXYZ/MaaUtils` 当前 ref 的最新 commit
  - build 仓库当前 commit
- 三者都与上一次 nightly 相同则跳过，不重新构建/发布
- 手动触发时可勾选 `force` 强制构建
- 拉取最新 `upstream-sync`
- 构建 MaaCore
- 发布滚动 release `nightly`
- 资产固定为：
  - `MaaCore-sdk-windows-x64-nightly.7z`
  - `MaaCore-sdk-windows-x64-nightly-symbols.7z`

SDK 里的 `deps.json` 使用 schemaVersion 2，运行库指向 `runtime-v1` bundle。

## 依赖资产

- FastDeploy 构建包：`fastdeploy-v1`
- 统一运行库包：`runtime-v1`
- 依赖版本：`tools/deps-versions.json`
- 运行库清单：`tools/runtime-manifest.json`

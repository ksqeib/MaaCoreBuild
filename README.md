# MaaCoreBuild

MaaCore 的独立构建/发布仓库。

本仓库不保存 MaaCore 源码，只保存：

- `overlay/CMakeLists.txt`：把上游 MaaCore 改造成独立构建的 CMake 入口
- `MaaUtils/`：MaaUtils 源码（vendored）
- `include/upstream`、`include/3rd`：MaaCore 需要的头文件
- `cmake/`、`tools/`：依赖组装、构建、打包脚本
- `scripts/prepare-source.ps1`：拉取上游代码并套用 overlay
- `.github/workflows/nightly.yml`：每日 nightly 构建与发布

## 工作方式

上游源码来自 `ksqeib/MaaCore` 的 `upstream-sync` 分支（由 MaaCore 仓库的同步 action 维护），不直接修改上游源码。

构建时：

1. `prepare-source.ps1` 克隆 `upstream-sync`
2. 用 `overlay/CMakeLists.txt` 覆盖上游 `CMakeLists.txt`
3. 注入 `MaaUtils/`、`include/`、`cmake/`、`tools/`
4. 在 `.work/MaaCore` 中执行 bootstrap / build / package

## 本地构建

```powershell
powershell -File .\scripts\prepare-source.ps1

Set-Location .\.work\MaaCore
powershell -File .\tools\bootstrap-standalone.ps1
powershell -File .\tools\build-maacore-only.ps1 -SkipBootstrap -UseSccache -NoFresh -Version nightly
powershell -File .\tools\package-sdk.ps1 -Version nightly -OutputDir D:\self\maa\MaaCoreBuild\dist
```

## Nightly

`.github/workflows/nightly.yml`：

- 每天 18:00 UTC 自动运行，也支持手动触发
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

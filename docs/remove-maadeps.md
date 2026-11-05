# 移除 MaaDeps 依赖（de-MaaDeps）

本文记录本仓库如何脱离 `MaaUtils/MaaDeps`，改用**上游官方二进制 + 官方源码**提供依赖，以及当前的发布流程。

## 结论速览

- 不再发布完整的 deps 包，也不再应用 MaaDeps 的自定义 patch。
- `deps/` 在 `bootstrap` 时本地组装：
  - OpenCV 4.12.0（官方 Windows 包，固定 URL）
  - ONNXRuntime 1.19.2 DirectML（官方 NuGet，固定 URL）
  - Boost 1.89.0（优先从 `build-libs-v1` 预编译包获取；缺失时回退官方源码，仅编译 Regex）
  - zlib 1.3.1（优先从 `build-libs-v1` 预编译包获取；缺失时回退官方源码，静态库）
- FastDeploy 1.0.8（`MaaXYZ/FastDeploy` 源码 + 固定 commit）没有匹配的上游 Windows 预编译包，由本仓库构建并单独发布一个约 15 MB 的小包（含 `DirectML.dll`）。
- Boost.Regex / zlib 的静态库单独发布为约 27 MB 的 `build-libs-v1` 小包；它只是构建期输入，不进 SDK。
- `MaaUtils` 由 `tools/deps-versions.json` 固定上游 ref，`prepare-source.ps1` 拉取，不 vendored。
- `tools/fastdeploy-manifest.json` 现在锚定的是 **FastDeploy 小包**的 URL + SHA-256。
- 首次 bootstrap 仍需下载 OpenCV / ONNXRuntime / FastDeploy（约 200 MB）；Boost/zlib 默认直接使用 `build-libs`，不再下载约 190 MB 的 Boost 源码。默认 `-ReleaseOnly`，只组装 Release 依赖。需要 Debug 依赖时用 `-Full`（或在 pwsh 中直接传 `-ReleaseOnly:$false`）。之后直接复用 `deps/`。
- 实测通过：Release / Debug 构建、`AsstLoadResource` / `AsstCreate`、FastDeploy OCR 推理、ONNXRuntime 会话、Boost.Process 子进程。

## 目录与职责

```
deps/                        不入库；bootstrap 时本地生成
├── include/                 OpenCV / ONNXRuntime / FastDeploy / Boost / zlib 头文件
├── lib/                     Release 导入库 / 静态库
│   ├── opencv_world4.lib       从官方 DLL 生成的导入库（指向 opencv_world4_maa.dll）
│   ├── onnxruntime.lib         从官方 DLL 生成的导入库（指向 onnxruntime_maa.dll）
│   ├── boost_regex.lib         官方源码编译
│   ├── zlib.lib                官方源码编译（静态）
│   └── cmake/                  OpenCV / Boost 的自定义 CONFIG 文件
├── bin/                     Release DLL
├── debug/                   Debug 库/DLL
├── share/                   FastDeploy 的 CMake config
└── runtime/maa-x64-windows/ 构建产物复制用运行时 DLL（含 msvc-debug/）

MaaUtils/                    由 prepare-source.ps1 从上游拉取，随工程编译
cmake/
├── maadeps.cmake            CMake 适配层（triplet、maadeps_install、OpenCV/ZLIB 路径）
└── upstream/
    ├── OpenCVConfig.cmake   官方 OpenCV + _maa 命名适配
    └── BoostConfig.cmake    官方 Boost + 编译宏
tools/
├── fastdeploy-manifest.json FastDeploy 小包清单（URL + sha256 + 版本）
├── build-libs-manifest.json Boost.Regex / zlib 构建期依赖包清单
├── fetch-deps.ps1           下载 FastDeploy + build-libs 小包 + 调用本地依赖组装
├── build-upstream-deps.ps1  下载官方包、必要时编译 Boost/zlib、组装 deps/
├── pack-fastdeploy.ps1      把 deps/ 中的 FastDeploy 打成小包
├── pack-build-libs.ps1      把 deps/ 中的 Boost.Regex / zlib 打成小包
├── bootstrap-standalone.ps1 构建前统一入口
└── package-sdk.ps1          打 SDK 发布包
```

## 首次构建

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\bootstrap-standalone.ps1
powershell -ExecutionPolicy Bypass -File .\tools\build-maacore-only.ps1 -SkipBootstrap -UseSccache -NoFresh
```

`fetch-deps.ps1` 的行为：

1. 读取 `tools/fastdeploy-manifest.json`，按平台选择 target（如 `windows-x64`）；
2. 命中 `deps/.bundle-version` 标记就直接返回；
3. 否则下载 FastDeploy 小包到 `.bootstrap/deps/`，校验 SHA-256 后解压；
4. 若 `tools/build-libs-manifest.json` 有已发布包，同样下载并解压 Boost.Regex / zlib；
5. 调用 `build-upstream-deps.ps1`：
   - 从官方固定 URL 下载 OpenCV / ORT（缓存到 `.bootstrap/upstream-deps`）
   - Boost/zlib：有 build-libs 时直接复制；没有时下载官方源码并编译
   - 生成 `_maa` 导入库
   - 组装 `deps/`
6. 校验 `include/`、`lib/`、`share/`、`runtime/maa-x64-windows/` 是否齐全。

## 从官方源码/发布物重建 deps

```powershell
# 强制重新下载 FastDeploy 并重新组装
powershell -File .\tools\fetch-deps.ps1 -Force

# 只重跑官方依赖组装（使用现有 deps/ 或 manifest 中的 FastDeploy）
powershell -File .\tools\build-upstream-deps.ps1

# 强制从官方源码编译 Boost.Regex / zlib（跳过 build-libs）
powershell -File .\tools\build-upstream-deps.ps1 -Full

# 指定本地 FastDeploy 来源
powershell -File .\tools\build-upstream-deps.ps1 -FastDeployFrom C:\path\to\fastdeploy
```

脚本会：

1. 下载并校验官方 OpenCV / ORT / Boost / zlib（带固定 SHA-256）；
2. 解压 OpenCV SFX、NuGet 包和源码包；
3. 用 CMake 编译 zlib 的 Release/Debug 静态库；
4. 用 CMake 编译 Boost.Regex 的 Release/Debug 静态库；
5. 从官方 OpenCV/ORT DLL 生成 `_maa` 命名的导入库；
6. 从 FastDeploy 小包复制 FastDeploy + `DirectML.dll`；
7. 组装 `deps/`（含 Debug 配置）；
8. 复制 `cmake/upstream/` 下的 CMake config。

FastDeploy 小包按以下顺序取用：

1. `-FastDeployFrom`；
2. 现有 `deps/include/fastdeploy`；
3. 下载 `-FastDeployUrl`（默认 `fastdeploy-v2`）。

## 发布 FastDeploy 小包

FastDeploy 的 MaaCore 适配代码会跟随上游新增 API（例如 PP-OCRv6 的 `ppocr_v6.h`），所以不能一直使用旧的 `fastdeploy-v1` 二进制包。源码与 commit 固定在 `tools/deps-versions.json`：

```json
"fastdeploy": {
  "repo": "https://github.com/MaaXYZ/FastDeploy.git",
  "ref": "dev",
  "commit": "e11935e4595360e7038573db1a7ab08dd0e096ec"
}
```

本地重建：

```powershell
# 1. 准备 OpenCV/ORT/Eigen/DirectML 依赖树（Debug + Release；会复用 fastdeploy-v1 里的 Eigen/DirectML）
.\tools\build-upstream-deps.ps1 -DepsDir .\fd-deps -Full

# 2. 从固定 commit 的源码构建 FastDeploy（Release + Debug）
.\tools\build-fastdeploy.ps1 `
  -FastDeploySrc D:\self\maa\FastDeploy `
  -BuildDepsRoot .\fd-deps `
  -OutputDir .\fd-stage

# 3. 打包并更新 manifest
.\tools\pack-fastdeploy.ps1 -DepsDir .\fd-stage -BundleVersion v2 -UpdateManifest
```

CI 使用 `.github/workflows/build-fastdeploy.yml`，发布后同样需要提交 `tools/fastdeploy-manifest.json`。

FastDeploy 包内容：

```
include/fastdeploy、Eigen、eigen3、nlohmann
lib/fastdeploy_ppocr.lib
bin/fastdeploy_ppocr_maa.dll
bin/DirectML.dll
share/fastdeploy_ppocr
debug/lib/fastdeploy_ppocr.lib
debug/bin/fastdeploy_ppocr_maa.dll
```

> 这个 FastDeploy 包是 **bootstrap 的构建期输入**（头文件、导入库、DLL、DirectML）。客户端运行库使用下面的统一 runtime bundle，不需要直接处理这个包。

## 发布 build-libs 小包（Boost.Regex + zlib）

```powershell
# 1. 生成完整依赖树（Release + Debug）
.\tools\build-upstream-deps.ps1 -OnlyBuildLibs -Full -DepsDir .\build-libs-deps

# 2. 打包并更新 manifest
.\tools\pack-build-libs.ps1 -DepsDir .\build-libs-deps -BundleVersion v1 -UpdateManifest
```

生成 `dist/MaaCore-build-libs-windows-x64-v1.zip`（约 27 MB），上传到 tag 为 `build-libs-v1` 的 GitHub Release，再提交 `tools/build-libs-manifest.json`。

内容包括：

```
include/boost/...
include/zlib.h
include/zconf.h
lib/boost_regex.lib
lib/zlib.lib
debug/lib/boost_regexd.lib
debug/lib/zlibd.lib
build-info.json
```

- 只给构建机用，不进 SDK、不进 runtime bundle。
- 静态库与 MSVC 工具链/CRT 绑定；`build-info.json` 记录 Boost/zlib 版本、MSVC toolset、CRT。
- 升级 Boost / zlib / VS 工具链后，把 `BundleVersion` 升到 `v2` 并重新发布。
- CI 使用 `.github/workflows/build-libs.yml`，与 nightly 完全独立。

## 发布 SDK

```powershell
powershell -File .\tools\package-sdk.ps1 -Version v0.1.4
```

默认使用 7z（不可用时回退 zip），输出两个归档，根目录不套版本目录：

```
dist/MaaCore-sdk-windows-x64-v0.1.4.7z
  bin/MaaCore.dll
  bin/MaaUtils.dll
  deps.json
  README.md
  LICENSE.md

dist/MaaCore-sdk-windows-x64-v0.1.4-symbols.7z
  bin/MaaCore.pdb
  bin/MaaUtils.pdb
```

- 默认不打包第三方 DLL（OpenCV / ONNXRuntime / DirectML / FastDeploy），客户端根据 `deps.json` 下载统一的 runtime bundle。
- 默认不打包 PDB，PDB 单独放在 `-symbols` 归档。
- 默认不打包头文件；需要时加 `-IncludeHeaders`，需要第三方 DLL 时加 `-IncludeRuntime`。
- `deps.json` 使用 `schemaVersion: 2`，包含：
  - `build`：Boost / zlib 等静态构建依赖
  - `runtime.windows-x64.bundle`：统一运行库 zip 的 URL / SHA-256 / size
  - `runtime.windows-x64.files`：每个运行库 DLL 的依赖名、版本、SHA-256

发布包由本地 `tools/package-sdk.ps1` 生成；nightly 由 `.github/workflows/nightly.yml` 构建并发布到滚动 `nightly` release。

## 发布运行库 bundle

```powershell
powershell -File .\tools\pack-runtime.ps1 -BundleVersion v1 -UpdateManifest
```

生成 `dist/MaaCore-runtime-windows-x64-v1.zip`（约 37 MB），上传到 tag 为 `runtime-v1` 的 GitHub Release，再提交 `tools/runtime-manifest.json`。

运行库 bundle 只包含运行期 DLL：

```
opencv_world4_maa.dll
onnxruntime_maa.dll
DirectML.dll
fastdeploy_ppocr_maa.dll
```

Boost / zlib 是静态链接，不在 bundle 里。客户端只需要：

1. 读 `deps.json` 的 `runtime.windows-x64.bundle`
2. 下载并校验 SHA-256 / size
3. 解压到 `bin/`
4. 可选按 `runtime.windows-x64.files` 校验每个 DLL

不需要分别处理 OpenCV 的 exe、ONNX Runtime 的 nupkg。

## 关于 MaaDeps 的 patch

这些 patch 已全部不再使用：

| Patch | 处理 |
|---|---|
| ORT `revert-pr-21492`（Min/Max NaN） | 不再应用，使用官方 ORT 语义 |
| ORT 的 CMake / clang / RC / PR 系列 patch | 不需要，直接使用官方二进制 |
| Boost.Asio `windows_handle_inheritance` | 不再应用 |
| Boost.Asio `windows_alloca_header` | 不再应用 |
| Boost.Asio `0001-add-options` | 用 `BOOST_ASIO_DISABLE_BOOST_DATE_TIME` / `BOOST_ASIO_DISABLE_BOOST_CONTEXT_FIBER` 替代 |
| Boost.Process `opt-filesystem` | 用 `BOOST_PROCESS_USE_STD_FS` 替代 |
| FastDeploy `float16` | Windows 无关，未应用 |
| OpenCV / zlib / DirectML | 本来就没有 MaaDeps patch |

保留了三个**适配层**（不是行为 patch）：

1. **`_maa` 命名 + 导入库**
   官方 DLL 重命名为 `opencv_world4_maa.dll` / `onnxruntime_maa.dll`，导入库由 `dumpbin` + `lib /def` 从官方 DLL 生成。这样 MaaCore 和 FastDeploy DLL 共用同一个模块。
2. **Boost.Process v1 命名空间**
   Boost 1.89 单体版把 v1 API 放进 `boost::process::v1`。`MaaUtils/include/MaaUtils/IOStream/BoostIO.hpp` 用 `__has_include(<boost/process/v1.hpp>)` 兼容新旧两种布局。
3. **FastDeploy**
   当前没有匹配的上游 Windows 预编译包，使用 MaaDeps 构建出的 `fastdeploy_ppocr`；Windows 上它本身没有 MaaDeps 源码 patch。

## 风险与边界

1. **首次 bootstrap 仍要下载 OpenCV / ORT / FastDeploy**：约 200 MB；Boost/zlib 默认直接使用 `build-libs`，不再下载 Boost 源码或现场编译。之后有本地 `.bootstrap/deps` 缓存和 `deps/` 复用。
2. **ORT Min/Max NaN patch 被去掉**：如果某个模型在 `Min/Max` 中遇到 NaN，结果会与旧 MaaDeps 版不同；当前 OCR/ONNX 测试未触发。
3. **Boost.Asio socket 继承 patch 被去掉**：PlayTools 的 TCP socket 不再强制 `NO_HANDLE_INHERIT`；子进程侧仍有 MaaUtils 的 `prevent_inherit`。
4. **FastDeploy 从源码构建**：固定 `MaaXYZ/FastDeploy` commit，由 `build-fastdeploy.ps1` 产出；升级 MaaCore OCR 代码时可能需要同步升级 FastDeploy commit 并重发 `fastdeploy-vN`。
5. **Debug 依赖按需组装**：默认 `-ReleaseOnly` 不生成 Debug Boost/zlib/OpenCV/运行库；需要 Debug 时用 `-Full`。FastDeploy 的 Debug 导入库/DLL 仍会保留，因为它的 CMake config 会校验所有配置。
6. **升级依赖**：官方版本/URL/SHA-256 在 `tools/deps-versions.json`；修改后跑 `fetch-deps.ps1 -Force`。Boost/zlib 还需重新发布 `build-libs`。

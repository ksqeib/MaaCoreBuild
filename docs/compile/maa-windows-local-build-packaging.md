---
title: MAA Windows 本地编译与打包指南
published: 2026-08-28
updated: 2026-08-28
description: 记录 MAA 在 Windows x64 上的本地编译、发布、安装与打包流程，适合 dev-v2 分支参考
tags: [MAA, Windows, CMake, VisualStudio, DotNet, PowerShell]
category: 项目
draft: false
---

本文整理的是 **MAA `dev-v2` 分支在 Windows x64 上的本地编译与打包流程**。内容偏向手动构建，适合需要本地调试、验证产物或准备发布包时参考。

> 说明：官方 `tools/local-install.bat` 内部会创建 `global.json` 并锁定 .NET SDK `10.0.302`。如果本机只安装了更新的 SDK 版本，例如 `10.0.400`，脚本可能会直接退出。本文改为手动执行各步骤，避免被脚本版本限制卡住。

---

## 一、环境准备

### 1. 需要安装的工具

| 工具 | 版本要求 | 说明 |
|---|---|---|
| Visual Studio | 2026 Community | 勾选「基于 C++ 的桌面开发」+「.NET 桌面开发」 |
| CMake | 3.23+ | 加入 PATH |
| Python | 3.x | 加入 PATH |
| .NET SDK | 10.0.x | 使用 `dotnet --version` 确认 |
| Git | 任意 | 需要支持 submodule |
| 7-Zip | 任意 | 用于最终打包，速度比 PowerShell 自带压缩更快 |

### 2. 建议确认

```powershell
dotnet --version
cmake --version
python --version
```

---

## 二、克隆仓库

```powershell
git clone --recurse-submodules https://github.com/MaaAssistantArknights/MaaAssistantArknights.git -b dev-v2 --single-branch
cd MaaAssistantArknights
```

如果仓库已经克隆，但没有带上子模块：

```powershell
git submodule update --init --depth 1
```

---

## 三、下载第三方依赖（MaaDeps）

如果网络环境不稳定，先配置代理：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
```

然后下载依赖：

```powershell
python tools/maadeps-download.py
```

脚本会下载两个包：

- `MaaDeps-x64-windows-devel.tar.xz`：编译时使用的头文件和静态库
- `MaaDeps-x64-windows-runtime.tar.xz`：运行时 DLL，例如 OpenCV、ONNX Runtime、FastDeploy 等

解压后放到 `src/MaaUtils/MaaDeps/`，CMake 配置时会自动识别。

### 常见情况

- **runtime 包下载超时**：脚本通常会保留已下载的 `devel` 包，再次运行时可以继续。
- **想手动下载**：也可以用 `curl.exe` 通过代理下载后，再用 Python 的 `tarfile` 解压到 `src/MaaUtils/MaaDeps/`。

---

## 四、CMake 配置

```powershell
cmake --preset windows-x64
```

常用 Preset 的含义如下：

| Preset | 用途 |
|---|---|
| `windows-x64` | 本地开发调试，包含 `debug_demo`、`ResourceUpdater` 等目标 |
| `windows-publish-x64` | CI 发布打包，启用 `INSTALL_RESOURCE=ON`，会自动安装到 `install/` |

配置成功后会生成 `build/` 目录，Visual Studio 解决方案位于 `build/MAA.slnx`。

---

## 五、编译 C++ Core

```powershell
cmake --build --preset windows-x64-RelWithDebInfo --parallel 8
```

主要输出通常位于 `build/bin/RelWithDebInfo/`：

| 文件 | 说明 |
|---|---|
| `MaaCore.dll` | C++ 核心，负责图像识别和任务调度 |
| `MaaUtils.dll` | 通用工具库 |
| `MaaAppHostStub.exe` | 原生启动器，用于替换 .NET apphost |
| `MAA.Updater.exe` | 自动更新器 |

---

## 六、编译并发布 WPF GUI（.NET）

先还原 NuGet 包：

```powershell
dotnet restore src/MaaWpfGui/MaaWpfGui.csproj -p:Platform=x64
```

然后发布到 `install/` 目录：

```powershell
dotnet publish src/MaaWpfGui/MaaWpfGui.csproj -c Release -p:Platform=x64 -o install
```

发布时 `nbeauty2` 会自动运行，把 .NET 运行时 DLL 整理到 `install/externals/`，便于保持根目录整洁。

---

## 七、安装 C++ 产物到 `install/`

```powershell
cmake --install build --config RelWithDebInfo --prefix install
```

这一步会把 C++ 相关产物和运行时 DLL 一并安装到 `install/`，包括 OpenCV、ONNX Runtime、DirectML、FastDeploy 等依赖。

---

## 八、下载 MaaFramework ControlUnit DLL

MAA 的 Win32 控制器和 MaaFw ADB 控制器依赖 MaaFramework 提供的 ControlUnit DLL，这些文件**不在本仓库内构建**，需要单独下载。

同样，如果需要代理：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
```

下载到 `install/`：

```powershell
python tools/maafw-control-unit-download.py --output-dir install
```

脚本会拉取 MaaFramework `v5.9.2` 对应的文件，通常包括：

| 文件 | 用途 |
|---|---|
| `MaaWin32ControlUnit.dll` | Win32 窗口绑定控制 |
| `MaaAdbControlUnit.dll` | ADB 触控模式 |
| `MaaCustomControlUnit.dll` | 自定义控制接口 |
| `MaaGamepadControlUnit.dll` | 手柄支持 |

---

## 九、后处理：清理与补充文件

```powershell
# 用 MaaAppHostStub 替换 .NET apphost，方便 MAA.exe 脱离目录时给出友好提示
if (Test-Path "build\bin\RelWithDebInfo\MaaAppHostStub.exe") {
    if (Test-Path "install\MAA.dll") {
        Copy-Item "build\bin\RelWithDebInfo\MaaAppHostStub.exe" "install\MAA.exe" -Force
    }
}

# 复制依赖安装脚本
Copy-Item "tools\DependencySetup_依赖库安装.bat" "install\" -Force

# 清理不需要的文件
Remove-Item "install\*.pdb" -Force -ErrorAction SilentlyContinue
Remove-Item "install\*.bak" -Force -ErrorAction SilentlyContinue
Remove-Item "install\msvc-debug" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "install\*.h" -Force -ErrorAction SilentlyContinue
```

---

## 十、打包成 zip

建议使用 **7-Zip** 打包，速度和压缩率都比 PowerShell 的 `Compress-Archive` 更好。

```powershell
$7z = "C:\Program Files\7-Zip-Zstandard\7z.exe"
& $7z a -tzip -mx=5 -mmt=on "D:\self\MAA-release.zip" ".\install\*"
```

### 参数说明

- `-tzip`：输出 zip 格式
- `-mx=5`：压缩级别 5，兼顾速度和体积
- `-mmt=on`：启用多线程

---

## 十一、`install/` 最终文件结构

```text
install/
├── MAA.exe                      ← 双击启动（MaaAppHostStub，原生 apphost）
├── MAA.dll                      ← WPF GUI 本体（.NET 10）
├── MAA.runtimeconfig.json
├── MAA.deps.json
├── MAA.Updater.exe              ← 自动更新器
├── MaaCore.dll                  ← C++ 核心
├── MaaUtils.dll
├── MaaWin32ControlUnit.dll      ← Win32 控制单元（来自 MaaFramework）
├── MaaAdbControlUnit.dll        ← ADB 控制单元
├── MaaCustomControlUnit.dll
├── MaaGamepadControlUnit.dll
├── opencv_world4_maa.dll        ← 图像处理
├── onnxruntime_maa.dll          ← 模型推理
├── fastdeploy_ppocr_maa.dll     ← OCR
├── DirectML.dll                 ← GPU 加速（可删除，不影响核心功能）
├── hostfxr.dll                  ← .NET host（nbeauty2 已 patch）
├── hostpolicy.dll
├── DependencySetup_依赖库安装.bat  ← VC 运行库安装脚本
├── res_updater.exe
├── externals/                   ← .NET 运行时 DLL（nbeauty2 整理）
├── resource/                    ← 游戏资源（JSON、模板图像）
└── Res/                         ← WPF 界面资源
```

---

## 十二、完整命令速查

```powershell
$PROXY = "http://127.0.0.1:7890"
$7z    = "C:\Program Files\7-Zip-Zstandard\7z.exe"

Set-Location "D:\self\MaaAssistantArknights"

# ① 依赖下载
$env:HTTPS_PROXY = $PROXY
python tools/maadeps-download.py

# ② CMake 配置 + 编译
cmake --preset windows-x64
cmake --build --preset windows-x64-RelWithDebInfo --parallel 8

# ③ .NET 还原 + 发布
dotnet restore src/MaaWpfGui/MaaWpfGui.csproj -p:Platform=x64
dotnet publish src/MaaWpfGui/MaaWpfGui.csproj -c Release -p:Platform=x64 -o install

# ④ C++ 安装到 install/
cmake --install build --config RelWithDebInfo --prefix install

# ⑤ MaaFramework ControlUnit DLL
$env:HTTPS_PROXY = $PROXY
python tools/maafw-control-unit-download.py --output-dir install

# ⑥ 后处理
if ((Test-Path "build\bin\RelWithDebInfo\MaaAppHostStub.exe") -and (Test-Path "install\MAA.dll")) {
    Copy-Item "build\bin\RelWithDebInfo\MaaAppHostStub.exe" "install\MAA.exe" -Force
}
Copy-Item "tools\DependencySetup_依赖库安装.bat" "install\" -Force
Remove-Item "install\*.pdb","install\*.bak","install\*.h" -Force -ErrorAction SilentlyContinue
Remove-Item "install\msvc-debug" -Recurse -Force -ErrorAction SilentlyContinue

# ⑦ 7z 打包
& $7z a -tzip -mx=5 -mmt=on "D:\self\MAA-release.zip" ".\install\*"

Write-Host "打包完成：D:\self\MAA-release.zip"
```

---

## 十三、常见问题

### Q1：`maadeps-download.py` 下载超时

先设置代理后重试：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
python tools/maadeps-download.py
```

### Q2：`local-install.bat` 报错退出

这是因为脚本内部锁定了 .NET SDK `10.0.302`，并且 `rollForward` 被设置为 `disable`。如果本机安装的是其他版本，建议直接按本文步骤手动构建。

### Q3：编译时提示 `project.assets.json` 缺失

先执行 `dotnet restore src/MaaWpfGui/MaaWpfGui.csproj`。

### Q4：运行时 ADB / Win32 控制模式无法初始化

通常是缺少 MaaFramework 的 ControlUnit DLL，请执行第八步补齐。

### Q5：想在 Visual Studio 中调试

打开 `build/MAA.slnx`，将启动项目设为 `MaaWpfGui`，然后按 `F5` 即可。运行时 DLL 已通过 junction 链接到 `build/bin/RelWithDebInfo/`，一般无需手动复制 `resource/`。



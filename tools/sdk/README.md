# MaaCore SDK

适用于其他启动器集成的 MaaCore 独立发行包（Windows x64）。

## 主包内容

7z 根目录：

```
bin/
  MaaCore.dll          MaaCore 主库（C ABI，见 include/AsstCaller.h）
  MaaUtils.dll         MaaCore 依赖的通用库
deps.json              构建/运行依赖清单（schemaVersion 2）
README.md
LICENSE.md
```

**运行库不在主包内。** 客户端根据 `deps.json` 下载一个统一的 runtime bundle。

## `deps.json`（schemaVersion 2）

```json
{
  "schemaVersion": 2,
  "maaCore": {
    "version": "v0.1.4",
    "commit": "..."
  },
  "build": {
    "boost": { "version": "1.89.0", "linkage": "static" },
    "zlib": { "version": "1.3.1", "linkage": "static" }
  },
  "runtime": {
    "windows-x64": {
      "bundle": {
        "url": "https://.../MaaCore-runtime-windows-x64-v2.zip",
        "sha256": "...",
        "size": 39516630
      },
      "files": {
        "opencv_world4_maa.dll": {
          "dependency": "opencv",
          "version": "4.12.0",
          "sha256": "..."
        },
        "onnxruntime_maa.dll": {
          "dependency": "onnxruntime",
          "version": "1.19.2",
          "flavor": "directml",
          "sha256": "..."
        },
        "DirectML.dll": {
          "dependency": "directml",
          "version": "1.15.4",
          "sha256": "..."
        },
        "fastdeploy_ppocr_maa.dll": {
          "dependency": "fastdeploy",
          "version": "1.0.8",
          "commit": "...",
          "sha256": "..."
        }
      }
    }
  }
}
```

- `build` 只包含静态链接进 MaaCore 的依赖，运行时不需要额外文件。
- `runtime.windows-x64.bundle` 是统一的运行库 zip，包含 `files` 里列出的所有 DLL。
- `files` 里每个 DLL 都有版本和 SHA-256，客户端可以判断是否需要更新。
- 不需要知道 OpenCV 的 exe、ONNX Runtime 的 nupkg 怎么解包；直接使用 runtime bundle 即可。

## 客户端接入流程

1. 解压主包，把 `bin/MaaCore.dll`、`bin/MaaUtils.dll` 放到目标目录。
2. 读取 `deps.json` 的 `runtime.windows-x64.bundle`。
3. 下载 bundle，校验 `sha256` 和 `size`。
4. 解压到 `bin/`（bundle 根目录就是这些 DLL）。
5. 可选：按 `runtime.windows-x64.files` 逐个校验 SHA-256。
6. 比较 `bundle.sha256` 或 `files[*].version` / `files[*].sha256` 判断是否需要更新运行库。

这样客户端只依赖一个 runtime bundle，不需要分别处理 OpenCV/ONNXRuntime/DirectML/FastDeploy 的官方包格式。

## 符号包

同一次发布还会提供：

```
MaaCore-sdk-windows-x64-<version>-symbols.7z
  bin/MaaCore.pdb
  bin/MaaUtils.pdb
```

主包默认不包含 PDB。

## 头文件

主包默认不包含头文件。需要集成时请使用仓库内的 `include/upstream/`：

- `AsstCaller.h`
- `AsstCallerExtra.h`
- `AsstPort.h`
- `MaaCore.h`

也可以在打包时加 `-IncludeHeaders` 把公开头文件一起放进去。

## 版本与兼容性

- 本包由 `ksqeib/MaaCore` 的独立构建流程产出，不是 MAA 官方发布包。
- `MaaCore.dll`、`MaaUtils.dll` 与 runtime bundle 必须整体匹配；升级时请同时更新 `deps.json` 中列出的依赖。
- `AsstGetVersion()` 返回构建时的版本（发布包通常是 `v*` tag）。

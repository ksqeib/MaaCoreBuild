# MaaCore Standalone Agent Rules

## Scope

This repository is maintained only for building:

- `MaaCore.dll`
- `MaaCore.pdb`
- an optional launcher-facing SDK archive (`tools/package-sdk.ps1`)

No GUI, packaging of `resource/`, or runtime functional validation is required in this repo workflow.

## Non-Goals

- Do not run parent-repository build flow.
- Do not depend on sparse checkout of parent repository.
- Do not require `resource/` for build success.

## Dependency Policy

- Keep API headers in `include/upstream/` (tracked in this repo).
- Keep required third-party headers in `include/3rd/` (tracked in this repo).
- Keep `MaaUtils/` as an external checkout configured by `tools/deps-versions.json` (`maautils.ref` or `maautils.commit`), not a vendored copy. `prepare-source.ps1` injects the `MAADEPS_DIR` / `MAA_DEPS_CONFIG` hook into `MaaUtils.cmake` after checkout.
- Keep binary deps through `deps/`, assembled locally by `tools/fetch-deps.ps1` / `tools/build-upstream-deps.ps1`.
- OpenCV / ONNXRuntime are downloaded from their official fixed URLs.
- Boost.Regex / zlib are build-only static libraries. Prefer the prebuilt `build-libs` bundle pinned by `tools/build-libs-manifest.json`; fall back to official source builds when the manifest has no published bundle. Do not publish a full deps bundle.
- `tools/fastdeploy-manifest.json` pins the build-time FastDeploy bundle (headers/libs/DLLs/DirectML).
- `tools/runtime-manifest.json` pins the client-facing unified runtime DLL bundle (OpenCV/ORT/DirectML/FastDeploy) with per-file SHA-256.
- `deps.json` in the SDK uses schemaVersion 2: `build` (static Boost/zlib) + `runtime.<target>.bundle/files`.
- Do not reintroduce `MaaUtils/MaaDeps` as a submodule or download path.
- Do not apply MaaDeps patches.

## Build Contract

- Build target: `MaaCore`
- Configuration: `RelWithDebInfo` (default)
- Expected outputs:
  - `build-standalone/bin/RelWithDebInfo/MaaCore.dll`
  - `build-standalone/bin/RelWithDebInfo/MaaCore.pdb`


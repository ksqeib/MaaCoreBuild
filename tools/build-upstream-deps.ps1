<#
.SYNOPSIS
    Assemble deps/ from upstream official binaries (no MaaDeps, no patches).

.DESCRIPTION
    Downloads the official OpenCV / ONNXRuntime DirectML / Boost / zlib artifacts,
    builds the two small libraries that need compiling (Boost.Regex and zlib),
    generates `_maa`-named import libraries from the official DLLs, and lays
    everything out in the layout MaaCore's CMake expects.

    FastDeploy (plus DirectML.dll) is the only component without a matching
    upstream Windows prebuilt package. It is provided as a small separate bundle:
    -FastDeployFrom, an existing deps/ tree, or -FastDeployUrl.

    FastDeploy is the only component without a matching upstream Windows binary.
    It is copied from -FastDeployFrom when given, otherwise from an existing
    deps/ tree, otherwise from the previous dependency bundle.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\build-upstream-deps.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\build-upstream-deps.ps1 `
        -FastDeployFrom C:\path\to\old\deps
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$DepsDir = "",
    [string]$CacheDir = "",
    [string]$FastDeployFrom = "",
    [string]$FastDeployUrl = "https://github.com/ksqeib/MaaCoreBuild/releases/download/fastdeploy-v1/MaaCore-fastdeploy-windows-x64-v1.zip",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($DepsDir)) {
    $DepsDir = Join-Path $RepoRoot "deps"
}
if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    $CacheDir = Join-Path $RepoRoot ".bootstrap\upstream-deps"
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "==> $Name"
    & $Action
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Sha256
    )

    if (Test-Path $Destination) {
        if ((Get-Sha256 $Destination) -eq $Sha256) {
            Write-Host "  cached: $(Split-Path -Leaf $Destination)"
            return
        }
        Remove-Item -LiteralPath $Destination -Force
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $partial = "$Destination.part"
    if (Test-Path $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    Write-Host "  downloading: $Url"
    $client = New-Object System.Net.WebClient
    try {
        if ($env:HTTPS_PROXY) {
            $client.Proxy = New-Object System.Net.WebProxy($env:HTTPS_PROXY)
        }
        $client.DownloadFile($Url, $partial)
    }
    finally {
        $client.Dispose()
    }

    $actual = Get-Sha256 $partial
    if ($actual -ne $Sha256) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for $Url. Expected $Sha256, got $actual"
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Expand-ZipArchive {
    param([string]$Archive, [string]$Destination)
    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

function Expand-TarGz {
    param([string]$Archive, [string]$Destination)
    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & tar -xzf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract $Archive"
    }
}

function Get-MsvcTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe was not found. Install Visual Studio C++ build tools."
    }
    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) {
        throw "Visual Studio C++ build tools were not found."
    }
    $toolsRoot = Join-Path $installationPath "VC\Tools\MSVC"
    $toolset = Get-ChildItem $toolsRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $toolset) {
        throw "No MSVC toolset found under $toolsRoot"
    }
    $bin = Join-Path $toolset.FullName "bin\Hostx64\x64"
    return @{
        Dumpbin = Join-Path $bin "dumpbin.exe"
        Lib     = Join-Path $bin "lib.exe"
    }
}

function New-ImportLibrary {
    param(
        [string]$DllPath,
        [string]$LibraryName,
        [string]$OutputLib,
        [hashtable]$Tools
    )

    if (-not (Test-Path $DllPath)) {
        throw "DLL not found for import library generation: $DllPath"
    }

    $lines = & $Tools.Dumpbin /nologo /exports $DllPath
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for $DllPath"
    }

    $names = foreach ($line in $lines) {
        if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$') {
            $Matches[1]
        }
    }
    $names = @($names | Sort-Object -Unique)
    if ($names.Count -eq 0) {
        throw "No exports found in $DllPath"
    }

    $defPath = [System.IO.Path]::ChangeExtension($OutputLib, ".def")
    $def = "LIBRARY $LibraryName`nEXPORTS`n" + (($names | ForEach-Object { "  $_" }) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($defPath, $def, (New-Object System.Text.ASCIIEncoding))

    Write-Host "  generating import library: $(Split-Path -Leaf $OutputLib) ($($names.Count) exports)"
    & $Tools.Lib /nologo /def:$defPath /out:$OutputLib /machine:x64
    if ($LASTEXITCODE -ne 0) {
        throw "lib.exe failed for $OutputLib"
    }

    Remove-Item -LiteralPath $defPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ([System.IO.Path]::ChangeExtension($OutputLib, ".exp")) -Force -ErrorAction SilentlyContinue
}

function Copy-IfExists {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Source) {
        $parent = Split-Path -Parent $Destination
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -Recurse
        return $true
    }
    return $false
}

function Resolve-FastDeploySource {
    if (-not [string]::IsNullOrWhiteSpace($FastDeployFrom)) {
        if (Test-Path (Join-Path $FastDeployFrom "include\fastdeploy")) {
            return $FastDeployFrom
        }
        $nested = Join-Path $FastDeployFrom "deps"
        if (Test-Path (Join-Path $nested "include\fastdeploy")) {
            return $nested
        }
        throw "-FastDeployFrom does not contain include/fastdeploy: $FastDeployFrom"
    }

    if (Test-Path (Join-Path $DepsDir "include\fastdeploy")) {
        return $DepsDir
    }

    $bundle = Join-Path $CacheDir "fastdeploy.zip"
    if (-not (Test-Path $bundle)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "  downloading FastDeploy bundle: $FastDeployUrl"
        $client = New-Object System.Net.WebClient
        try {
            if ($env:HTTPS_PROXY) {
                $client.Proxy = New-Object System.Net.WebProxy($env:HTTPS_PROXY)
            }
            $client.DownloadFile($FastDeployUrl, $bundle)
        }
        finally {
            $client.Dispose()
        }
    }

    $extract = Join-Path $staging "fastdeploy-source"
    Expand-ZipArchive $bundle $extract
    $root = $extract
    $nested = Join-Path $extract "deps"
    if (Test-Path (Join-Path $nested "include\fastdeploy")) {
        $root = $nested
    }
    if (-not (Test-Path (Join-Path $root "include\fastdeploy"))) {
        throw "FastDeploy bundle does not contain include/fastdeploy: $bundle"
    }
    return $root
}

$versionsPath = Join-Path $PSScriptRoot "deps-versions.json"
if (-not (Test-Path $versionsPath)) {
    throw "Dependency version manifest not found: $versionsPath"
}
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json

$assets = foreach ($name in @("opencv", "onnxruntime", "boost", "zlib")) {
    $dep = $versions.dependencies.$name
    if ($null -eq $dep -or [string]::IsNullOrWhiteSpace($dep.file) -or [string]::IsNullOrWhiteSpace($dep.url) -or [string]::IsNullOrWhiteSpace($dep.sha256)) {
        throw "deps-versions.json is missing file/url/sha256 for '$name'"
    }
    @{
        File   = [string]$dep.file
        Url    = [string]$dep.url
        Sha256 = [string]$dep.sha256
    }
}

New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("maa-upstream-deps-" + [Guid]::NewGuid().ToString("N"))
$stageDeps = Join-Path $staging "deps"
New-Item -ItemType Directory -Path $stageDeps -Force | Out-Null

try {
    Invoke-Step "Download upstream artifacts" {
        foreach ($asset in $assets) {
            $path = Join-Path $CacheDir $asset.File
            Invoke-Download -Url $asset.Url -Destination $path -Sha256 $asset.Sha256
        }
    }

    $opencvExe = Join-Path $CacheDir $versions.dependencies.opencv.file
    $ortNupkg = Join-Path $CacheDir $versions.dependencies.onnxruntime.file
    $boostTar = Join-Path $CacheDir $versions.dependencies.boost.file
    $zlibTar = Join-Path $CacheDir $versions.dependencies.zlib.file

    $opencvRoot = Join-Path $staging "opencv"
    $ortRoot = Join-Path $staging "ort"
    $boostRoot = Join-Path $staging "boost"
    $zlibRoot = Join-Path $staging "zlib"

    Invoke-Step "Extract upstream artifacts" {
        $process = Start-Process -FilePath $opencvExe -ArgumentList "-o$opencvRoot", "-y" -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) {
            throw "OpenCV self-extractor failed with exit code $($process.ExitCode)"
        }
        Expand-ZipArchive $ortNupkg $ortRoot
        Expand-TarGz $boostTar $boostRoot
        Expand-TarGz $zlibTar $zlibRoot
    }

    $opencvBuild = Join-Path $opencvRoot "opencv\build"
    $opencvReleaseDll = Join-Path $opencvBuild "x64\vc16\bin\opencv_world4120.dll"
    $opencvDebugDll = Join-Path $opencvBuild "x64\vc16\bin\opencv_world4120d.dll"
    $ortReleaseDll = Join-Path $ortRoot "runtimes\win-x64\native\onnxruntime.dll"
    $boostSrc = Join-Path $boostRoot "boost_1_89_0"
    $zlibSrc = Join-Path $zlibRoot "zlib-1.3.1"

    foreach ($required in @($opencvReleaseDll, $opencvDebugDll, $ortReleaseDll, $boostSrc, $zlibSrc)) {
        if (-not (Test-Path $required)) {
            throw "Upstream artifact is incomplete, missing: $required"
        }
    }

    $fastDeployRoot = Resolve-FastDeploySource
    Write-Host "==> FastDeploy source: $fastDeployRoot"

    $directmlDll = Join-Path $fastDeployRoot "bin\DirectML.dll"
    if (-not (Test-Path $directmlDll)) {
        $directmlDll = Join-Path $fastDeployRoot "DirectML.dll"
    }
    if (-not (Test-Path $directmlDll)) {
        throw "DirectML.dll is not present in the FastDeploy bundle: $fastDeployRoot"
    }

    $zlibBuild = Join-Path $staging "zlib-build"
    $zlibInstall = Join-Path $staging "zlib-install"
    Invoke-Step "Build zlib (upstream source)" {
        & cmake -S $zlibSrc -B $zlibBuild -DBUILD_SHARED_LIBS=OFF -DZLIB_BUILD_EXAMPLES=OFF "-DCMAKE_INSTALL_PREFIX=$zlibInstall"
        if ($LASTEXITCODE -ne 0) { throw "zlib configure failed" }
        & cmake --build $zlibBuild --config Release --target install --parallel 8
        if ($LASTEXITCODE -ne 0) { throw "zlib release build failed" }
        & cmake --build $zlibBuild --config Debug --target install --parallel 8
        if ($LASTEXITCODE -ne 0) { throw "zlib debug build failed" }
    }

    $boostRegexSrc = Join-Path $staging "boost-regex-src"
    $boostRegexBuild = Join-Path $staging "boost-regex-build"
    Invoke-Step "Build Boost.Regex (upstream source)" {
        New-Item -ItemType Directory -Path $boostRegexSrc -Force | Out-Null
        $boostSrcCmake = $boostSrc -replace '\\', '/'
        @"
cmake_minimum_required(VERSION 3.20)
project(boost_regex CXX)

add_library(boost_regex STATIC
    "$boostSrcCmake/libs/regex/src/posix_api.cpp"
    "$boostSrcCmake/libs/regex/src/wide_posix_api.cpp")
target_include_directories(boost_regex PUBLIC "$boostSrcCmake")
target_compile_features(boost_regex PUBLIC cxx_std_17)
set_target_properties(boost_regex PROPERTIES OUTPUT_NAME boost_regex)
"@ | Set-Content (Join-Path $boostRegexSrc "CMakeLists.txt") -NoNewline
        & cmake -S $boostRegexSrc -B $boostRegexBuild
        if ($LASTEXITCODE -ne 0) { throw "Boost.Regex configure failed" }
        & cmake --build $boostRegexBuild --config Release --parallel 8
        if ($LASTEXITCODE -ne 0) { throw "Boost.Regex release build failed" }
        & cmake --build $boostRegexBuild --config Debug --parallel 8
        if ($LASTEXITCODE -ne 0) { throw "Boost.Regex debug build failed" }
    }

    $boostRegexRelease = Get-ChildItem $boostRegexBuild -Recurse -File -Filter "boost_regex.lib" |
        Where-Object { $_.FullName -match '\\Release\\' } | Select-Object -First 1
    $boostRegexDebug = Get-ChildItem $boostRegexBuild -Recurse -File -Filter "boost_regex.lib" |
        Where-Object { $_.FullName -match '\\Debug\\' } | Select-Object -First 1
    if ($null -eq $boostRegexRelease -or $null -eq $boostRegexDebug) {
        throw "Boost.Regex libraries were not produced under $boostRegexBuild"
    }

    $tools = Get-MsvcTools

    Invoke-Step "Assemble dependency tree" {
        $dirs = @(
            "include",
            "lib",
            "bin",
            "share",
            "debug\lib",
            "debug\bin",
            "runtime\maa-x64-windows",
            "runtime\maa-x64-windows\msvc-debug",
            "lib\cmake\opencv4",
            "lib\cmake\Boost-1.89.0"
        )
        foreach ($dir in $dirs) {
            New-Item -ItemType Directory -Path (Join-Path $stageDeps $dir) -Force | Out-Null
        }

        Copy-Item (Join-Path $opencvBuild "include") (Join-Path $stageDeps "include\opencv4") -Recurse -Force
        Copy-Item (Join-Path $ortRoot "build\native\include") (Join-Path $stageDeps "include\onnxruntime") -Recurse -Force
        Copy-Item (Join-Path $boostSrc "boost") (Join-Path $stageDeps "include\boost") -Recurse -Force
        Copy-Item (Join-Path $zlibInstall "include\zlib.h") (Join-Path $stageDeps "include\zlib.h") -Force
        Copy-Item (Join-Path $zlibInstall "include\zconf.h") (Join-Path $stageDeps "include\zconf.h") -Force

        Copy-Item (Join-Path $fastDeployRoot "include\fastdeploy") (Join-Path $stageDeps "include\fastdeploy") -Recurse -Force
        foreach ($extra in @("Eigen", "eigen3", "nlohmann")) {
            $extraSource = Join-Path $fastDeployRoot "include\$extra"
            if (Test-Path $extraSource) {
                Copy-Item $extraSource (Join-Path $stageDeps "include\$extra") -Recurse -Force
            }
        }

        Copy-Item (Join-Path $fastDeployRoot "lib\fastdeploy_ppocr.lib") (Join-Path $stageDeps "lib\fastdeploy_ppocr.lib") -Force
        Copy-Item (Join-Path $fastDeployRoot "bin\fastdeploy_ppocr_maa.dll") (Join-Path $stageDeps "bin\fastdeploy_ppocr_maa.dll") -Force
        Copy-Item (Join-Path $fastDeployRoot "share\fastdeploy_ppocr") (Join-Path $stageDeps "share\fastdeploy_ppocr") -Recurse -Force
        if (Test-Path (Join-Path $fastDeployRoot "debug\lib\fastdeploy_ppocr.lib")) {
            Copy-Item (Join-Path $fastDeployRoot "debug\lib\fastdeploy_ppocr.lib") (Join-Path $stageDeps "debug\lib\fastdeploy_ppocr.lib") -Force
        }
        else {
            Copy-Item (Join-Path $fastDeployRoot "lib\fastdeploy_ppocr.lib") (Join-Path $stageDeps "debug\lib\fastdeploy_ppocr.lib") -Force
        }
        if (Test-Path (Join-Path $fastDeployRoot "debug\bin\fastdeploy_ppocr_maa.dll")) {
            Copy-Item (Join-Path $fastDeployRoot "debug\bin\fastdeploy_ppocr_maa.dll") (Join-Path $stageDeps "debug\bin\fastdeploy_ppocr_maa.dll") -Force
        }
        else {
            Copy-Item (Join-Path $fastDeployRoot "bin\fastdeploy_ppocr_maa.dll") (Join-Path $stageDeps "debug\bin\fastdeploy_ppocr_maa.dll") -Force
        }

        Copy-Item $opencvReleaseDll (Join-Path $stageDeps "bin\opencv_world4_maa.dll") -Force
        Copy-Item $opencvDebugDll (Join-Path $stageDeps "debug\bin\opencv_world4d_maa.dll") -Force
        Copy-Item $ortReleaseDll (Join-Path $stageDeps "bin\onnxruntime_maa.dll") -Force
        Copy-Item $ortReleaseDll (Join-Path $stageDeps "debug\bin\onnxruntime_maa.dll") -Force
        Copy-Item $directmlDll (Join-Path $stageDeps "bin\DirectML.dll") -Force
        Copy-Item $directmlDll (Join-Path $stageDeps "debug\bin\DirectML.dll") -Force

        Copy-Item (Join-Path $zlibInstall "lib\zlibstatic.lib") (Join-Path $stageDeps "lib\zlib.lib") -Force
        if (Test-Path (Join-Path $zlibInstall "lib\zlibstaticd.lib")) {
            Copy-Item (Join-Path $zlibInstall "lib\zlibstaticd.lib") (Join-Path $stageDeps "debug\lib\zlibd.lib") -Force
        }
        else {
            Copy-Item (Join-Path $zlibInstall "lib\zlibstatic.lib") (Join-Path $stageDeps "debug\lib\zlibd.lib") -Force
        }
        Copy-Item $boostRegexRelease.FullName (Join-Path $stageDeps "lib\boost_regex.lib") -Force
        Copy-Item $boostRegexDebug.FullName (Join-Path $stageDeps "debug\lib\boost_regexd.lib") -Force

        New-ImportLibrary -DllPath (Join-Path $stageDeps "bin\opencv_world4_maa.dll") -LibraryName "opencv_world4_maa.dll" -OutputLib (Join-Path $stageDeps "lib\opencv_world4.lib") -Tools $tools
        New-ImportLibrary -DllPath (Join-Path $stageDeps "debug\bin\opencv_world4d_maa.dll") -LibraryName "opencv_world4d_maa.dll" -OutputLib (Join-Path $stageDeps "debug\lib\opencv_world4d.lib") -Tools $tools
        New-ImportLibrary -DllPath (Join-Path $stageDeps "bin\onnxruntime_maa.dll") -LibraryName "onnxruntime_maa.dll" -OutputLib (Join-Path $stageDeps "lib\onnxruntime.lib") -Tools $tools
        Copy-Item (Join-Path $stageDeps "lib\onnxruntime.lib") (Join-Path $stageDeps "debug\lib\onnxruntime.lib") -Force

        Copy-Item (Join-Path $PSScriptRoot "..\cmake\upstream\OpenCVConfig.cmake") (Join-Path $stageDeps "lib\cmake\opencv4\OpenCVConfig.cmake") -Force
        Copy-Item (Join-Path $PSScriptRoot "..\cmake\upstream\BoostConfig.cmake") (Join-Path $stageDeps "lib\cmake\Boost-1.89.0\BoostConfig.cmake") -Force

        $releaseRuntime = @(
            "opencv_world4_maa.dll",
            "onnxruntime_maa.dll",
            "DirectML.dll",
            "fastdeploy_ppocr_maa.dll"
        )
        foreach ($name in $releaseRuntime) {
            Copy-Item (Join-Path $stageDeps "bin\$name") (Join-Path $stageDeps "runtime\maa-x64-windows\$name") -Force
        }

        $debugRuntime = @(
            "opencv_world4d_maa.dll",
            "onnxruntime_maa.dll",
            "DirectML.dll",
            "fastdeploy_ppocr_maa.dll"
        )
        foreach ($name in $debugRuntime) {
            Copy-Item (Join-Path $stageDeps "debug\bin\$name") (Join-Path $stageDeps "runtime\maa-x64-windows\msvc-debug\$name") -Force
        }
    }

    Invoke-Step "Install deps/" {
        if (Test-Path $DepsDir) {
            Remove-Item $DepsDir -Recurse -Force
        }
        Move-Item -LiteralPath $stageDeps -Destination $DepsDir
    }

    Write-Host ""
    Write-Host "Upstream dependency tree ready: $DepsDir"
    Write-Host "  OpenCV     4.12.0 official"
    Write-Host "  ONNXRuntime 1.19.2 DirectML official"
    Write-Host "  DirectML   from FastDeploy bundle (official Microsoft binary)"
    Write-Host "  Boost      1.89.0 official source (Regex only)"
    Write-Host "  zlib       1.3.1 official source"
    Write-Host "  FastDeploy from: $fastDeployRoot"
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

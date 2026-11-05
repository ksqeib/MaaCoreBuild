param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$BuildDir = "build-standalone",
    [string]$Config = "RelWithDebInfo",
    [string]$Generator = "Visual Studio 18 2026",
    [string]$Arch = "x64",
    [int]$Parallel = 0,
    [switch]$NoFresh,
    [switch]$UseSccache,
    [switch]$SkipBootstrap,
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host "==> $Name"
    & $Action
}

function Enter-MsvcDevShell {
    param(
        [string]$Arch = "x64"
    )

    if (Get-Command cl -ErrorAction SilentlyContinue) {
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere was not found. Install Visual Studio C++ build tools, or run this script from a Developer PowerShell."
    }

    $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsInstallPath) {
        throw "Visual Studio C++ build tools were not found."
    }

    $vsDevCmd = Join-Path $vsInstallPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        throw "VsDevCmd.bat was not found: $vsDevCmd"
    }

    Write-Host "Loading MSVC developer environment: $vsDevCmd"
    $envLines = & cmd.exe /s /c "`"$vsDevCmd`" -arch=$Arch -host_arch=$Arch >nul && set"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load MSVC developer environment."
    }

    foreach ($line in $envLines) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator)
        $value = $line.Substring($separator + 1)
        Set-Item -Path "Env:$name" -Value $value
    }
}

if (-not $SkipBootstrap) {
    Invoke-Step "Bootstrap standalone dependencies" {
        $bootstrapArgs = @(
            "-File", (Join-Path $RepoRoot "tools\bootstrap-standalone.ps1"),
            "-RepoRoot", $RepoRoot
        )

        Invoke-External -FilePath "powershell.exe" -Arguments $bootstrapArgs
    }
}

$buildPath = Join-Path $RepoRoot $BuildDir
$effectiveGenerator = $Generator
$effectiveParallel = $Parallel

if ($Config -eq "Debug") {
    $debugBoost = Join-Path $RepoRoot "deps\debug\lib\boost_regexd.lib"
    if (-not (Test-Path $debugBoost)) {
        throw 'Debug dependencies are not installed. Run tools/bootstrap-standalone.ps1 -ReleaseOnly:$false first.'
    }
}

if ($effectiveParallel -le 0) {
    $effectiveParallel = [Math]::Max(1, [Environment]::ProcessorCount)
    Write-Host "Build parallelism: auto-detected $effectiveParallel logical processor(s)."
} else {
    Write-Host "Build parallelism: $effectiveParallel job(s)."
}

if ($UseSccache -and $effectiveGenerator -like "Visual Studio *") {
    Write-Host "-UseSccache requested; switching generator from '$effectiveGenerator' to 'Ninja Multi-Config' so CMAKE_*_COMPILER_LAUNCHER is honored."
    $effectiveGenerator = "Ninja Multi-Config"
}

if ($effectiveGenerator -like "Ninja*") {
    Enter-MsvcDevShell -Arch $Arch

    if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
        throw "Ninja was not found in PATH after loading the MSVC developer environment. Install Ninja or Visual Studio CMake tools."
    }
}

$cachePath = Join-Path $buildPath "CMakeCache.txt"
if ((Test-Path $cachePath) -and $NoFresh) {
    $removeStaleBuildDir = $false
    $cachedGeneratorLine = Select-String -Path $cachePath -Pattern '^CMAKE_GENERATOR:INTERNAL=' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cachedGeneratorLine) {
        $cachedGenerator = $cachedGeneratorLine.Line.Substring('CMAKE_GENERATOR:INTERNAL='.Length)
        if ($cachedGenerator -ne $effectiveGenerator) {
            Write-Host "Existing build directory uses generator '$cachedGenerator', requested '$effectiveGenerator'. Removing stale build directory."
            $removeStaleBuildDir = $true
        }
    }

    if ($UseSccache -and -not $removeStaleBuildDir) {
        $cachedDebugInfoLine = Select-String -Path $cachePath -Pattern '^CMAKE_MSVC_DEBUG_INFORMATION_FORMAT:' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1
        $cachedModuleScanLine = Select-String -Path $cachePath -Pattern '^CMAKE_CXX_SCAN_FOR_MODULES:' -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1

        if ((-not $cachedDebugInfoLine) -or ($cachedDebugInfoLine.Line -notmatch '=Embedded$') -or
            (-not $cachedModuleScanLine) -or ($cachedModuleScanLine.Line -notmatch '=OFF$')) {
            Write-Host "Existing build directory was not configured for sccache-friendly MSVC flags. Removing stale build directory."
            $removeStaleBuildDir = $true
        }
    }

    if ($removeStaleBuildDir) {
        Remove-Item -Path $buildPath -Recurse -Force
    }
}

Invoke-Step "Configure CMake" {
    $cmakeArgs = @("-S", $RepoRoot, "-B", $buildPath, "-G", $effectiveGenerator)
    if (-not $NoFresh) {
        $cmakeArgs = @("--fresh") + $cmakeArgs
    }
    if ($effectiveGenerator -like "Visual Studio *") {
        $cmakeArgs += @("-A", $Arch)
    }
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $cmakeArgs += "-DMAA_HASH_VERSION=$Version"
    }
    if ($UseSccache) {
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if (-not $sccacheCmd) {
            throw "-UseSccache was specified but sccache was not found in PATH."
        }
        $cmakeArgs += @(
            "-DCMAKE_C_COMPILER_LAUNCHER=sccache",
            "-DCMAKE_CXX_COMPILER_LAUNCHER=sccache",
            "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded",
            "-DCMAKE_CXX_SCAN_FOR_MODULES=OFF"
        )
    }
    Invoke-External -FilePath "cmake" -Arguments $cmakeArgs
}

Invoke-Step "Build MaaCore target" {
    Invoke-External -FilePath "cmake" -Arguments @("--build", $buildPath, "--config", $Config, "--target", "MaaCore", "--parallel", $effectiveParallel)
}

$dllPath = Join-Path $buildPath "bin\$Config\MaaCore.dll"
$pdbPath = Join-Path $buildPath "bin\$Config\MaaCore.pdb"

Invoke-Step "Validate build outputs" {
    if (-not (Test-Path $dllPath)) {
        throw "Build finished but MaaCore.dll was not found: $dllPath"
    }

    if (-not (Test-Path $pdbPath)) {
        throw "Build finished but MaaCore.pdb was not found: $pdbPath"
    }

    Write-Host "MaaCore.dll: $dllPath"
    Write-Host "MaaCore.pdb: $pdbPath"
}


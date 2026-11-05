<#
.SYNOPSIS
    Package the MaaCore-owned binaries and a dependency manifest.

.DESCRIPTION
    OpenCV / ONNXRuntime / DirectML / FastDeploy are not bundled. The launcher is
    expected to provide them based on bin/deps.json. The main archive contains:

        bin/MaaCore.dll
        bin/MaaUtils.dll
        bin/deps.json
        README.md
        LICENSE.md

    PDB files are published as a separate "-symbols" archive. Headers and runtime
    DLLs can be included with -IncludeHeaders / -IncludeRuntime if needed.

    Uses 7z when available (much smaller for PDB/PE files), otherwise falls back
    to zip.

.EXAMPLE
    powershell -File .\tools\package-sdk.ps1 -Version v0.1.4
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$BuildDir = "build-standalone",
    [string]$Config = "RelWithDebInfo",
    [string]$OutputDir = "",
    [string]$Version = "",
    [string]$AssetVersion = "",
    [string]$Target = "windows-x64",
    [switch]$IncludeRuntime,
    [switch]$IncludeHeaders
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "dist"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = git -C $RepoRoot describe --tags --always --dirty 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Version)) {
        $Version = "dev"
    }
}
$Version = $Version.Trim() -replace '[^\w.\-+]', '-'
if ([string]::IsNullOrWhiteSpace($AssetVersion)) {
    $AssetVersion = $Version
}
$AssetVersion = $AssetVersion.Trim() -replace '[^\w.\-+]', '-'

$buildBin = Join-Path $RepoRoot (Join-Path $BuildDir "bin\$Config")
$dllPath = Join-Path $buildBin "MaaCore.dll"
$pdbPath = Join-Path $buildBin "MaaCore.pdb"
$maaUtilsPath = Join-Path $buildBin "MaaUtils.dll"
$maaUtilsPdb = Join-Path $buildBin "MaaUtils.pdb"

foreach ($path in @($dllPath, $maaUtilsPath)) {
    if (-not (Test-Path $path)) {
        throw "Build output not found: $path. Run tools/build-maacore-only.ps1 first."
    }
}

$versionsPath = Join-Path $PSScriptRoot "deps-versions.json"
$runtimeManifestPath = Join-Path $PSScriptRoot "runtime-manifest.json"
if (-not (Test-Path $versionsPath)) { throw "Missing dependency version manifest: $versionsPath" }
if (-not (Test-Path $runtimeManifestPath)) { throw "Missing runtime dependency manifest: $runtimeManifestPath" }
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json
$runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json

function Get-SevenZip {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles "7-Zip\7z.exe"),
        "C:\Program Files\7-Zip-Zstandard\7z.exe"
    )
    if ($env:ProgramFiles -and (Test-Path ${env:ProgramFiles(x86)})) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe")
    }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function New-Archive {
    param(
        [string]$StagingDir,
        [string]$ArchivePath,
        [string]$SevenZip
    )

    if (Test-Path $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    if (-not [string]::IsNullOrWhiteSpace($SevenZip)) {
        Push-Location $StagingDir
        try {
            & $SevenZip a -t7z -mx=9 -mmt=on -y $ArchivePath "." | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "7z failed for $ArchivePath"
            }
        }
        finally {
            Pop-Location
        }
        return ".7z"
    }

    $fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $StagingDir -Recurse -File | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($StagingDir.Length).TrimStart('\', '/') -replace '\\', '/'
            $entry = $zip.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $fileStream = [System.IO.File]::OpenRead($_.FullName)
            try {
                $entryStream = $entry.Open()
                try {
                    $fileStream.CopyTo($entryStream)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
            finally {
                $fileStream.Dispose()
            }
        }
    }
    finally {
        $zip.Dispose()
    }
    return ".zip"
}

$sevenZip = Get-SevenZip
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maacore-sdk-" + [Guid]::NewGuid().ToString("N"))
$mainStaging = Join-Path $stagingRoot "main"
$symbolsStaging = Join-Path $stagingRoot "symbols"
$mainBin = Join-Path $mainStaging "bin"
$symbolsBin = Join-Path $symbolsStaging "bin"
New-Item -ItemType Directory -Path $mainBin -Force | Out-Null
New-Item -ItemType Directory -Path $symbolsBin -Force | Out-Null

try {
    Write-Host "Staging MaaCore-owned binaries"
    Copy-Item -LiteralPath $dllPath -Destination $mainBin -Force
    Copy-Item -LiteralPath $maaUtilsPath -Destination $mainBin -Force

    if ($IncludeRuntime) {
        $runtimeDir = Join-Path $RepoRoot "deps\runtime\maa-x64-windows"
        if (-not (Test-Path $runtimeDir)) {
            throw "Runtime dependency directory not found: $runtimeDir"
        }
        foreach ($dll in Get-ChildItem -LiteralPath $runtimeDir -File -Filter *.dll) {
            if ($dll.Name -eq 'MaaUtils.dll' -or $dll.Name -eq 'MaaCore.dll') { continue }
            Copy-Item -LiteralPath $dll.FullName -Destination $mainBin -Force
        }
    }

    if ($IncludeHeaders) {
        $publicInclude = Join-Path $RepoRoot "include\upstream"
        if (-not (Test-Path $publicInclude)) {
            throw "Public headers not found: $publicInclude"
        }
        New-Item -ItemType Directory -Path (Join-Path $mainStaging "include") -Force | Out-Null
        Get-ChildItem -LiteralPath $publicInclude -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $mainStaging "include") -Force
        }
    }

    if (Test-Path $pdbPath) {
        Copy-Item -LiteralPath $pdbPath -Destination $symbolsBin -Force
    }
    if (Test-Path $maaUtilsPdb) {
        Copy-Item -LiteralPath $maaUtilsPdb -Destination $symbolsBin -Force
    }

    $commit = git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $commit = "" }

    $runtimeTarget = $runtimeManifest.targets.$Target
    if ($null -eq $runtimeTarget) {
        throw "runtime-manifest.json has no target '$Target'"
    }
    if ($runtimeTarget.bundle.sha256 -eq ('0' * 64)) {
        throw "runtime-manifest.json still has a placeholder bundle sha256; run tools/pack-runtime.ps1 -UpdateManifest first"
    }

    $runtimeTargets = [ordered]@{}
    $runtimeTargets[$Target] = [ordered]@{
        bundle = $runtimeTarget.bundle
        files  = $runtimeTarget.files
    }

    $depsInfo = [ordered]@{
        schemaVersion = 2
        maaCore = [ordered]@{
            version = $Version
            commit  = $commit.Trim()
        }
        build = [ordered]@{
            boost = [ordered]@{
                version = [string]$versions.dependencies.boost.version
                linkage = "static"
            }
            zlib = [ordered]@{
                version = [string]$versions.dependencies.zlib.version
                linkage = "static"
            }
        }
        runtime = $runtimeTargets
    }
    $depsJson = $depsInfo | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText(
        (Join-Path $mainStaging "deps.json"),
        $depsJson,
        (New-Object System.Text.UTF8Encoding($false)))

    $sdkReadme = Join-Path $PSScriptRoot "sdk\README.md"
    if (Test-Path $sdkReadme) {
        Copy-Item -LiteralPath $sdkReadme -Destination (Join-Path $mainStaging "README.md") -Force
    }

    $license = Join-Path $RepoRoot "MaaUtils\LICENSE.md"
    if (Test-Path $license) {
        Copy-Item -LiteralPath $license -Destination (Join-Path $mainStaging "LICENSE.md") -Force
    }

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $archiveExt = ".zip"
    if (-not [string]::IsNullOrWhiteSpace($sevenZip)) {
        $archiveExt = ".7z"
    }

    $mainBase = "MaaCore-sdk-$Target-$AssetVersion"
    $mainPath = Join-Path $OutputDir ($mainBase + $archiveExt)
    New-Archive -StagingDir $mainStaging -ArchivePath $mainPath -SevenZip $sevenZip | Out-Null

    $symbolsBase = "MaaCore-sdk-$Target-$AssetVersion-symbols"
    $symbolsPath = Join-Path $OutputDir ($symbolsBase + $archiveExt)
    New-Archive -StagingDir $symbolsStaging -ArchivePath $symbolsPath -SevenZip $sevenZip | Out-Null

    Write-Host ""
    foreach ($item in @(
        @{ Name = "MaaCore"; Path = $mainPath },
        @{ Name = "Symbols"; Path = $symbolsPath }
    )) {
        $hash = (Get-FileHash -LiteralPath $item.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $sizeMb = [Math]::Round((Get-Item -LiteralPath $item.Path).Length / 1MB, 1)
        Write-Host "$($item.Name): $($item.Path)"
        Write-Host "  Size:   $sizeMb MB"
        Write-Host "  SHA256: $hash"
    }
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

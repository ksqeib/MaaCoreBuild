<#
.SYNOPSIS
    Package the build-only static libraries (Boost.Regex + zlib) as a small bundle.

.DESCRIPTION
    Boost and zlib are linked statically into MaaUtils.dll / MaaCore.dll, so they
    never appear in the SDK. Building them from source on every fresh CI runner
    is wasteful, though: Boost's source archive is ~190 MB and both libraries are
    only needed by the build machine.

    This script packages the headers and static libraries from a full deps/ tree
    into a reusable bundle:

        include/boost/...
        include/zlib.h
        include/zconf.h
        lib/boost_regex.lib
        lib/zlib.lib
        debug/lib/boost_regexd.lib
        debug/lib/zlibd.lib
        build-info.json

    tools/pack-build-libs.ps1 -UpdateManifest rewrites
    tools/build-libs-manifest.json with the bundle URL, SHA-256, size and the
    per-library hashes.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\pack-build-libs.ps1 -UpdateManifest
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$DepsDir = "",
    [string]$OutputDir = "",
    [string]$BundleVersion = "v1",
    [string]$Target = "windows-x64",
    [string]$RepoSlug = "",
    [switch]$UpdateManifest
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($DepsDir)) {
    $DepsDir = Join-Path $RepoRoot "deps"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "dist"
}
$versionsPath = Join-Path $PSScriptRoot "deps-versions.json"
$manifestPath = Join-Path $PSScriptRoot "build-libs-manifest.json"

if (-not (Test-Path $versionsPath)) {
    throw "Missing dependency version manifest: $versionsPath"
}
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
    $remote = git -C $RepoRoot remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
        throw "Could not determine repository slug. Pass -RepoSlug owner/repo."
    }
    $RepoSlug = $remote.Trim()
    if ($RepoSlug -match 'github\.com[:/](?<slug>[^/]+/[^/]+?)(\.git)?$') {
        $RepoSlug = $Matches['slug']
    }
    else {
        throw "Origin is not a GitHub remote: $remote. Pass -RepoSlug owner/repo."
    }
}

function Get-MsvcToolset {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return ""
    }
    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installationPath)) {
        return ""
    }
    $toolsRoot = Join-Path $installationPath "VC\Tools\MSVC"
    if (-not (Test-Path $toolsRoot)) {
        return ""
    }
    $toolset = Get-ChildItem $toolsRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $toolset) {
        return ""
    }
    return $toolset.Name
}

$required = @(
    @{ Source = "include\boost\version.hpp"; Destination = "include\boost\version.hpp" },
    @{ Source = "include\zlib.h"; Destination = "include\zlib.h" },
    @{ Source = "include\zconf.h"; Destination = "include\zconf.h" },
    @{ Source = "lib\boost_regex.lib"; Destination = "lib\boost_regex.lib" },
    @{ Source = "lib\zlib.lib"; Destination = "lib\zlib.lib" },
    @{ Source = "debug\lib\boost_regexd.lib"; Destination = "debug\lib\boost_regexd.lib" },
    @{ Source = "debug\lib\zlibd.lib"; Destination = "debug\lib\zlibd.lib" }
)

foreach ($file in $required) {
    if (-not (Test-Path (Join-Path $DepsDir $file.Source))) {
        throw "Missing build-only dependency: $(Join-Path $DepsDir $file.Source). Run tools/build-upstream-deps.ps1 -ReleaseOnly:`$false first."
    }
}

$assetName = "MaaCore-build-libs-$Target-$BundleVersion.zip"
$zipPath = Join-Path $OutputDir $assetName
$releaseTag = "build-libs-$BundleVersion"
$assetUrl = "https://github.com/$RepoSlug/releases/download/$releaseTag/$assetName"

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maacore-build-libs-" + [Guid]::NewGuid().ToString("N"))
$staging = Join-Path $stagingRoot "build-libs"
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    Write-Host "Staging build-only dependencies from $DepsDir"

    Copy-Item -LiteralPath (Join-Path $DepsDir "include\boost") -Destination (Join-Path $staging "include\boost") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $DepsDir "include\zlib.h") -Destination (Join-Path $staging "include\zlib.h") -Force
    Copy-Item -LiteralPath (Join-Path $DepsDir "include\zconf.h") -Destination (Join-Path $staging "include\zconf.h") -Force

    foreach ($file in @(
            "lib\boost_regex.lib",
            "lib\zlib.lib",
            "debug\lib\boost_regexd.lib",
            "debug\lib\zlibd.lib")) {
        $destination = Join-Path $staging $file
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $DepsDir $file) -Destination $destination -Force
    }

    $buildInfo = [ordered]@{
        schemaVersion = 1
        target        = $Target
        arch          = "x64"
        boost         = [string]$versions.dependencies.boost.version
        zlib          = [string]$versions.dependencies.zlib.version
        crtRelease    = "MD"
        crtDebug      = "MDd"
        msvcToolset   = Get-MsvcToolset
    }
    $buildInfoJson = $buildInfo | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText(
        (Join-Path $staging "build-info.json"),
        $buildInfoJson,
        (New-Object System.Text.UTF8Encoding($false)))

    $files = [ordered]@{
        "include/boost/version.hpp"    = [ordered]@{
            dependency = "boost"
            sha256     = ""
        }
        "include/zlib.h"               = [ordered]@{
            dependency = "zlib"
            sha256     = ""
        }
        "include/zconf.h"              = [ordered]@{
            dependency = "zlib"
            sha256     = ""
        }
        "lib/boost_regex.lib"          = [ordered]@{
            dependency = "boost"
            config     = "Release"
            sha256     = ""
        }
        "lib/zlib.lib"                 = [ordered]@{
            dependency = "zlib"
            config     = "Release"
            sha256     = ""
        }
        "debug/lib/boost_regexd.lib"   = [ordered]@{
            dependency = "boost"
            config     = "Debug"
            sha256     = ""
        }
        "debug/lib/zlibd.lib"          = [ordered]@{
            dependency = "zlib"
            config     = "Debug"
            sha256     = ""
        }
    }

    foreach ($name in $files.Keys) {
        $path = Join-Path $staging ($name -replace '/', '\')
        $files[$name]["sha256"] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Write-Host "Compressing to $zipPath"
    $fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $staging -Recurse -File | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($staging.Length).TrimStart('\', '/') -replace '\\', '/'
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
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $zipPath).Length
$sizeMb = [Math]::Round($size / 1MB, 1)

Write-Host ""
Write-Host "Created: $zipPath"
Write-Host "Size:    $sizeMb MB"
Write-Host "SHA256:  $hash"
Write-Host "URL:     $assetUrl"

if ($UpdateManifest) {
    $targetEntry = [ordered]@{
        url    = $assetUrl
        sha256 = $hash
        size   = $size
        build  = [ordered]@{
            boost       = [string]$versions.dependencies.boost.version
            zlib        = [string]$versions.dependencies.zlib.version
            msvcToolset = [string]$buildInfo.msvcToolset
            crtRelease  = "MD"
            crtDebug    = "MDd"
        }
        files  = $files
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        bundleVersion = $BundleVersion
        targets       = [ordered]@{}
    }
    $manifest.targets[$Target] = $targetEntry

    $json = $manifest | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
    Write-Host "Updated $manifestPath"
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Create a GitHub release tagged '$releaseTag' (or use an existing one)."
Write-Host "  2. Upload '$assetName' as a release asset."
Write-Host "  3. Commit tools/build-libs-manifest.json."

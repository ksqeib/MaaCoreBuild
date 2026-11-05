<#
.SYNOPSIS
    Download and verify the prebuilt MaaCore dependency bundle.

.DESCRIPTION
    The third-party binaries MaaCore needs (OpenCV / ONNXRuntime / fastdeploy_ppocr /
    Boost / zlib) are published as a single pinned release asset instead of being
    downloaded through the MaaDeps submodule. This script resolves the asset from
    tools/fastdeploy-manifest.json, verifies its SHA-256 and extracts it into <repo>/deps.

    The bundle is only needed to *build* MaaCore. Consumers of a released SDK package
    do not need to run this script.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER Target
    Manifest target key. Defaults to the host platform, e.g. windows-x64.

.PARAMETER ManifestPath
    Path to the deps manifest. Defaults to tools/fastdeploy-manifest.json.

.PARAMETER CacheDir
    Download cache directory. Defaults to <repo>/.bootstrap/deps.

.PARAMETER Force
    Re-download and re-extract even when the marker matches.
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Target = "",
    [string]$ManifestPath = (Join-Path $PSScriptRoot "fastdeploy-manifest.json"),
    [string]$CacheDir = "",
    [switch]$ReleaseOnly = $true,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Get-HostTarget {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($arch -eq "x64") {
        $arch = "x64"
    }
    elseif ($arch -eq "arm64") {
        $arch = "arm64"
    }
    elseif ($arch -eq "x86") {
        $arch = "x86"
    }

    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        return "windows-$arch"
    }
    if ($IsMacOS) {
        return "osx-$arch"
    }
    if ($IsLinux) {
        return "linux-$arch"
    }
    throw "Unsupported host OS; pass -Target explicitly."
}

function Get-ArchiveFileName {
    param([string]$Url)
    $name = ($Url -split '/')[-1]
    $name = $name.Split('?')[0]
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "deps.zip"
    }
    return $name
}

function Get-StringSha256 {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$Destination
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $uri = [Uri]$Url
    if ($uri.IsFile) {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $Destination -Force
        return
    }

    Write-Host "Downloading $Url"
    $client = New-Object System.Net.WebClient
    try {
        if ($env:HTTPS_PROXY) {
            $client.Proxy = New-Object System.Net.WebProxy($env:HTTPS_PROXY)
        }
        $client.DownloadFile($Url, $Destination)
    }
    finally {
        $client.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = Get-HostTarget
}

if (-not (Test-Path $ManifestPath)) {
    throw "Deps manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$entry = $manifest.targets.$Target
if ($null -eq $entry) {
    $known = ($manifest.targets.PSObject.Properties.Name -join ", ")
    throw "No dependency bundle published for target '$Target'. Known targets: $known"
}

foreach ($field in @("url", "sha256")) {
    if ([string]::IsNullOrWhiteSpace($entry.$field)) {
        throw "Deps manifest target '$Target' is missing '$field'."
    }
}

$expectedHash = ([string]$entry.sha256).ToLowerInvariant().Replace("sha256:", "")
if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw "Deps manifest target '$Target' has an invalid sha256 value: '$expectedHash'"
}
if ($expectedHash -eq ('0' * 64)) {
    throw "Deps manifest target '$Target' still has a placeholder sha256. Run tools/pack-fastdeploy.ps1 -UpdateManifest and publish the asset first."
}

$depsDir = Join-Path $RepoRoot "deps"
$markerPath = Join-Path $depsDir ".bundle-version"
$bundleVersion = [string]$manifest.bundleVersion
if ([string]::IsNullOrWhiteSpace($bundleVersion)) {
    $bundleVersion = $expectedHash
}

$depMode = if ($ReleaseOnly.IsPresent) { "release-only" } else { "full" }
$manifestHash = Get-StringSha256 ($bundleVersion + "|" + $Target + "|" + $expectedHash + "|" + $depMode)

if (-not $Force -and (Test-Path $markerPath)) {
    $marker = (Get-Content -LiteralPath $markerPath -Raw).Trim()
    if ($marker -eq $manifestHash) {
        Write-Host "Dependencies already present (bundle $bundleVersion, target $Target)."
        return
    }
}

# A locally assembled deps/ tree (tools/build-upstream-deps.ps1) has no bundle
# marker. Do not overwrite it just because the manifest changed; -Force does.
if (-not $Force -and (-not (Test-Path $markerPath))) {
    $requiredPaths = @("include", "lib", "share", "runtime\maa-x64-windows")
    $complete = $true
    foreach ($relative in $requiredPaths) {
        if (-not (Test-Path (Join-Path $depsDir $relative))) {
            $complete = $false
            break
        }
    }
    if ($complete) {
        Write-Host "Existing deps/ found without a bundle marker; assuming it is ready. Use -Force to re-download."
        return
    }
}

if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    $CacheDir = Join-Path $RepoRoot ".bootstrap\deps"
}
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

$archiveName = Get-ArchiveFileName $entry.url
$archivePath = Join-Path $CacheDir $archiveName

$needsDownload = $true
if ((Test-Path $archivePath) -and (-not $Force)) {
    $cachedHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($cachedHash -eq $expectedHash) {
        Write-Host "Using cached dependency bundle: $archivePath"
        $needsDownload = $false
    }
}

if ($needsDownload) {
    $partialPath = "$archivePath.part"
    if (Test-Path $partialPath) {
        Remove-Item -LiteralPath $partialPath -Force
    }
    Invoke-Download -Url $entry.url -Destination $partialPath

    $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        throw "Dependency bundle SHA-256 mismatch. Expected $expectedHash, got $actualHash. The download may be corrupt or the manifest is out of date."
    }

    Move-Item -LiteralPath $partialPath -Destination $archivePath -Force
}

$fastDeployDir = Join-Path $CacheDir ("fastdeploy-" + $bundleVersion)
if (Test-Path $fastDeployDir) {
    Remove-Item $fastDeployDir -Recurse -Force
}
New-Item -ItemType Directory -Path $fastDeployDir -Force | Out-Null

Write-Host "Extracting $archiveName to $fastDeployDir"
Expand-Archive -LiteralPath $archivePath -DestinationPath $fastDeployDir -Force

$fastDeployRoot = $fastDeployDir
$nested = Join-Path $fastDeployDir "deps"
if (Test-Path (Join-Path $nested "include\fastdeploy")) {
    $fastDeployRoot = $nested
}
if (-not (Test-Path (Join-Path $fastDeployRoot "include\fastdeploy"))) {
    throw "FastDeploy bundle extracted but include/fastdeploy is missing: $fastDeployRoot"
}

$buildScript = Join-Path $PSScriptRoot "build-upstream-deps.ps1"
$upstreamCache = Join-Path $RepoRoot ".bootstrap\upstream-deps"
& $buildScript -RepoRoot $RepoRoot -DepsDir $depsDir -FastDeployFrom $fastDeployRoot -CacheDir $upstreamCache -ReleaseOnly:$($ReleaseOnly.IsPresent)

$requiredPaths = @(
    (Join-Path $depsDir "include"),
    (Join-Path $depsDir "lib"),
    (Join-Path $depsDir "share"),
    (Join-Path $depsDir "runtime\maa-x64-windows")
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path $path)) {
        throw "Dependency assembly finished but required path is missing: $path"
    }
}

Set-Content -LiteralPath $markerPath -Value $manifestHash -NoNewline
Write-Host "Dependencies ready (bundle $bundleVersion, target $Target)."

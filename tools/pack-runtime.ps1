<#
.SYNOPSIS
    Package the runtime DLLs and update tools/runtime-manifest.json.

.DESCRIPTION
    The runtime bundle contains only the shared libraries MaaCore loads at
    runtime:

        opencv_world4_maa.dll
        onnxruntime_maa.dll
        DirectML.dll
        fastdeploy_ppocr_maa.dll

    Build-only dependencies (Boost / zlib static libraries) are not included.
    The bundle is a plain zip with the DLLs at its root, so a launcher can
    download it, verify the bundle hash and extract the files listed in
    runtime.windows-x64.files.

.EXAMPLE
    powershell -File .\tools\pack-runtime.ps1 -UpdateManifest
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$RuntimeDir = "",
    [string]$OutputDir = "",
    [string]$BundleVersion = "v1",
    [string]$Target = "windows-x64",
    [string]$RepoSlug = "",
    [switch]$UpdateManifest
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
    $RuntimeDir = Join-Path $RepoRoot "deps\runtime\maa-x64-windows"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $RepoRoot "dist"
}
$versionsPath = Join-Path $PSScriptRoot "deps-versions.json"
$manifestPath = Join-Path $PSScriptRoot "runtime-manifest.json"

if (-not (Test-Path $RuntimeDir)) {
    throw "Runtime directory not found: $RuntimeDir"
}
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

$files = [ordered]@{
    "opencv_world4_maa.dll" = [ordered]@{
        dependency = "opencv"
        version    = [string]$versions.dependencies.opencv.version
    }
    "onnxruntime_maa.dll" = [ordered]@{
        dependency = "onnxruntime"
        version    = [string]$versions.dependencies.onnxruntime.version
        flavor     = "directml"
    }
    "DirectML.dll" = [ordered]@{
        dependency = "directml"
        version    = [string]$versions.dependencies.directml.version
    }
    "fastdeploy_ppocr_maa.dll" = [ordered]@{
        dependency = "fastdeploy"
        version    = [string]$versions.dependencies.fastdeploy.version
        commit     = [string]$versions.dependencies.fastdeploy.commit
    }
}

foreach ($name in $files.Keys) {
    $path = Join-Path $RuntimeDir $name
    if (-not (Test-Path $path)) {
        throw "Runtime DLL is missing: $path"
    }
    $files[$name]["sha256"] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$assetName = "MaaCore-runtime-$Target-$BundleVersion.zip"
$zipPath = Join-Path $OutputDir $assetName
$releaseTag = "runtime-$BundleVersion"
$assetUrl = "https://github.com/$RepoSlug/releases/download/$releaseTag/$assetName"

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maacore-runtime-" + [Guid]::NewGuid().ToString("N"))
$staging = Join-Path $stagingRoot "runtime"
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    foreach ($name in $files.Keys) {
        Copy-Item -LiteralPath (Join-Path $RuntimeDir $name) -Destination (Join-Path $staging $name) -Force
    }

    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    Write-Host "Compressing to $zipPath"
    $fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $staging -File | Sort-Object Name | ForEach-Object {
            $entry = $zip.CreateEntry($_.Name, [System.IO.Compression.CompressionLevel]::Optimal)
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
        bundle = [ordered]@{
            url    = $assetUrl
            sha256 = $hash
            size   = $size
        }
        files  = $files
    }
    $manifest = [ordered]@{
        schemaVersion = 2
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
Write-Host "  3. Commit the updated tools/runtime-manifest.json."

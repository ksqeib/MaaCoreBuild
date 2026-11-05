<#
.SYNOPSIS
    Package the FastDeploy (plus DirectML.dll) part of deps/ as a small bundle.

.DESCRIPTION
    OpenCV / ONNXRuntime / Boost / zlib are downloaded from their official fixed
    URLs by tools/build-upstream-deps.ps1. Only FastDeploy has no matching
    upstream Windows prebuilt package, so it is published separately.

    The resulting zip contains include/, lib/, bin/, share/ and debug/ at its
    root, which is exactly the layout -FastDeployFrom expects.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\pack-fastdeploy.ps1 -UpdateManifest
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
$manifestPath = Join-Path $PSScriptRoot "fastdeploy-manifest.json"

if (-not (Test-Path (Join-Path $DepsDir "include\fastdeploy"))) {
    throw "Deps directory does not look like a deps tree: $DepsDir"
}

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

$assetName = "MaaCore-fastdeploy-$Target-$BundleVersion.zip"
$zipPath = Join-Path $OutputDir $assetName
$releaseTag = "fastdeploy-$BundleVersion"
$assetUrl = "https://github.com/$RepoSlug/releases/download/$releaseTag/$assetName"

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("maacore-fastdeploy-" + [Guid]::NewGuid().ToString("N"))
$staging = Join-Path $stagingRoot "fastdeploy"
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$includes = @(
    @{ Source = "include\fastdeploy"; Destination = "include\fastdeploy" },
    @{ Source = "include\Eigen"; Destination = "include\Eigen" },
    @{ Source = "include\eigen3"; Destination = "include\eigen3" },
    @{ Source = "include\nlohmann"; Destination = "include\nlohmann" }
)

$files = @(
    @{ Source = "lib\fastdeploy_ppocr.lib"; Destination = "lib\fastdeploy_ppocr.lib" },
    @{ Source = "bin\fastdeploy_ppocr_maa.dll"; Destination = "bin\fastdeploy_ppocr_maa.dll" },
    @{ Source = "bin\DirectML.dll"; Destination = "bin\DirectML.dll" },
    @{ Source = "debug\lib\fastdeploy_ppocr.lib"; Destination = "debug\lib\fastdeploy_ppocr.lib" },
    @{ Source = "debug\bin\fastdeploy_ppocr_maa.dll"; Destination = "debug\bin\fastdeploy_ppocr_maa.dll" }
)

try {
    Write-Host "Staging FastDeploy files from $DepsDir"

    foreach ($include in $includes) {
        $source = Join-Path $DepsDir $include.Source
        if (Test-Path $source) {
            $destination = Join-Path $staging $include.Destination
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
        }
    }

    foreach ($file in $files) {
        $source = Join-Path $DepsDir $file.Source
        if (-not (Test-Path $source)) {
            throw "Required FastDeploy file is missing: $source"
        }
        $destination = Join-Path $staging $file.Destination
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $share = Join-Path $DepsDir "share\fastdeploy_ppocr"
    if (-not (Test-Path $share)) {
        throw "Missing FastDeploy CMake config: $share"
    }
    New-Item -ItemType Directory -Path (Join-Path $staging "share") -Force | Out-Null
    Copy-Item -LiteralPath $share -Destination (Join-Path $staging "share\fastdeploy_ppocr") -Recurse -Force

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
$sizeMb = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)

Write-Host ""
Write-Host "Created: $zipPath"
Write-Host "Size:    $sizeMb MB"
Write-Host "SHA256:  $hash"
Write-Host "URL:     $assetUrl"

if ($UpdateManifest) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')
    $lines.Add('  "schemaVersion": 1,')
    $lines.Add("  `"bundleVersion`": `"$BundleVersion`",")
    $lines.Add('  "targets": {')
    $lines.Add("    `"$Target`": {")
    $lines.Add("      `"url`": `"$assetUrl`",")
    $lines.Add("      `"sha256`": `"$hash`"")
    $lines.Add('    }')
    $lines.Add('  }')
    $lines.Add('}')

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, ($lines -join "`n"), $utf8NoBom)
    Write-Host "Updated $manifestPath"
}

Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Create a GitHub release tagged '$releaseTag' (or use an existing one)."
Write-Host "  2. Upload '$assetName' as a release asset."
Write-Host "  3. Commit the updated tools/fastdeploy-manifest.json."

<#
.SYNOPSIS
    Materialize an upstream MaaCore tree with the standalone build overlay.

.DESCRIPTION
    Clones the upstream-sync branch (or a local MaaCore checkout), clones
    MaaUtils at the commit pinned in tools/deps-versions.json, applies the
    MaaUtils build patches, then overlays:
      overlay/CMakeLists.txt  -> MaaCore/CMakeLists.txt
      include/                -> MaaCore/include/
      cmake/                  -> MaaCore/cmake/
      tools/                  -> MaaCore/tools/

    The result is a self-contained tree that tools/build-maacore-only.ps1 can
    build without modifying upstream source manually.

.EXAMPLE
    powershell -File .\scripts\prepare-source.ps1
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$WorkDir = "",
    [string]$MaaCoreRepo = "https://github.com/ksqeib/MaaCore.git",
    [string]$Ref = "upstream-sync",
    [string]$LocalSource = "",
    [string]$MaaCoreCommit = "",
    [string]$MaaUtilsCommit = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    $WorkDir = Join-Path $RepoRoot ".work\MaaCore"
}

$parent = Split-Path -Parent $WorkDir
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$preserveNames = @("deps", ".bootstrap")
$preserveRoot = Join-Path $parent (".preserve-" + [Guid]::NewGuid().ToString("N"))
if (Test-Path $WorkDir) {
    foreach ($name in $preserveNames) {
        $existing = Join-Path $WorkDir $name
        if (Test-Path $existing) {
            New-Item -ItemType Directory -Path $preserveRoot -Force | Out-Null
            Move-Item -LiteralPath $existing -Destination (Join-Path $preserveRoot $name)
        }
    }
    Remove-Item $WorkDir -Recurse -Force
}

try {
    $source = if ([string]::IsNullOrWhiteSpace($LocalSource)) { $MaaCoreRepo } else { $LocalSource }
    Write-Host "==> Cloning MaaCore ($source, ref=$Ref)"
    $cloneArgs = @("clone", "--depth", "1")
    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        $cloneArgs += @("--branch", $Ref)
    }
    $cloneArgs += @($source, $WorkDir)
    & git @cloneArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone MaaCore from $source"
    }

    if (-not [string]::IsNullOrWhiteSpace($MaaCoreCommit)) {
        & git -C $WorkDir fetch --depth 1 origin $MaaCoreCommit
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch MaaCore commit $MaaCoreCommit" }
        & git -C $WorkDir checkout --detach FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { throw "Failed to checkout MaaCore commit $MaaCoreCommit" }
    }
}
finally {
    if (Test-Path $preserveRoot) {
        if (-not (Test-Path $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        foreach ($name in $preserveNames) {
            $preserved = Join-Path $preserveRoot $name
            if (Test-Path $preserved) {
                Move-Item -LiteralPath $preserved -Destination (Join-Path $WorkDir $name)
            }
        }
        Remove-Item -LiteralPath $preserveRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$versionsPath = Join-Path $RepoRoot "tools\deps-versions.json"
if (-not (Test-Path $versionsPath)) {
    throw "Missing dependency version manifest: $versionsPath"
}
$versions = Get-Content -LiteralPath $versionsPath -Raw | ConvertFrom-Json
$maaUtilsRepo = [string]$versions.dependencies.maautils.repo
$maaUtilsRef = [string]$versions.dependencies.maautils.ref
$maaUtilsPinned = [string]$versions.dependencies.maautils.commit
if (-not [string]::IsNullOrWhiteSpace($MaaUtilsCommit)) {
    $maaUtilsPinned = $MaaUtilsCommit
}
if ([string]::IsNullOrWhiteSpace($maaUtilsRepo) -or ([string]::IsNullOrWhiteSpace($maaUtilsRef) -and [string]::IsNullOrWhiteSpace($maaUtilsPinned))) {
    throw "deps-versions.json is missing maautils.repo and maautils.ref/commit"
}

$maaUtilsDir = Join-Path $WorkDir "MaaUtils"
if (-not [string]::IsNullOrWhiteSpace($maaUtilsPinned)) {
    Write-Host "==> Fetching MaaUtils ($maaUtilsRepo, commit=$maaUtilsPinned)"
}
else {
    Write-Host "==> Fetching MaaUtils latest ($maaUtilsRepo, ref=$maaUtilsRef)"
}
& git init --quiet $maaUtilsDir
if ($LASTEXITCODE -ne 0) { throw "git init failed for MaaUtils" }
& git -C $maaUtilsDir remote add origin $maaUtilsRepo
$fetchRef = if (-not [string]::IsNullOrWhiteSpace($maaUtilsPinned)) { $maaUtilsPinned } else { $maaUtilsRef }
& git -C $maaUtilsDir fetch --depth 1 origin $fetchRef
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch MaaUtils ref $fetchRef" }
& git -C $maaUtilsDir checkout --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw "Failed to checkout MaaUtils ref $fetchRef" }

$maaUtilsResolved = git -C $maaUtilsDir rev-parse HEAD
Write-Host "    MaaUtils commit: $maaUtilsResolved"

$patchDir = Join-Path $RepoRoot "patches"
if (Test-Path $patchDir) {
    Get-ChildItem -LiteralPath $patchDir -File -Filter "maa-utils-*.patch" | Sort-Object Name | ForEach-Object {
        Write-Host "==> Applying MaaUtils patch: $($_.Name)"
        & git -C $maaUtilsDir apply --check $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "MaaUtils patch does not apply: $($_.FullName)" }
        & git -C $maaUtilsDir apply $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "Failed to apply MaaUtils patch: $($_.FullName)" }
    }
}

Write-Host "==> Overlaying standalone build files"
Copy-Item -LiteralPath (Join-Path $RepoRoot "overlay\CMakeLists.txt") -Destination (Join-Path $WorkDir "CMakeLists.txt") -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "include") -Destination (Join-Path $WorkDir "include") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "cmake") -Destination (Join-Path $WorkDir "cmake") -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "tools") -Destination (Join-Path $WorkDir "tools") -Recurse -Force

$agent = Join-Path $RepoRoot "agent.md"
if (Test-Path $agent) {
    Copy-Item -LiteralPath $agent -Destination (Join-Path $WorkDir "agent.md") -Force
}

$commit = git -C $WorkDir rev-parse HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Could not read commit from $WorkDir"
}

Write-Host "==> Prepared: $WorkDir"
Write-Host "    commit: $commit"
Write-Host "    build with: powershell -File $WorkDir\tools\build-maacore-only.ps1 -SkipBootstrap -UseSccache -NoFresh"

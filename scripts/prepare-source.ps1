<#
.SYNOPSIS
    Materialize an upstream MaaCore tree with the standalone build overlay.

.DESCRIPTION
    Clones the upstream-sync branch (or a local MaaCore checkout), clones
    MaaUtils at the commit/ref pinned in tools/deps-versions.json, injects the
    standalone MAADEPS/MAA_DEPS_CONFIG hook, then overlays:
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

Write-Host "==> Applying MaaUtils standalone deps hook"
$maaUtilsCmake = Join-Path $maaUtilsDir "MaaUtils.cmake"
$content = [System.IO.File]::ReadAllText($maaUtilsCmake)
$pattern = '(?m)^[ \t]*set\(MAADEPS_DIR \$\{MAAUTILS_DIR\}/MaaDeps\)[ \t]*\r?\n[ \t]*include\(\$\{MAADEPS_DIR\}/maadeps\.cmake\)'
$match = [regex]::Match($content, $pattern)
if (-not $match.Success) {
    throw "Could not find the MAADEPS block in $maaUtilsCmake"
}
$replacement = @(
    '# Allow a super-project to pin its own dependency directory (e.g. a repo-local'
    '# deps/ tree) instead of the submodule''s MaaDeps. Default remains MaaDeps.'
    'if(NOT DEFINED MAADEPS_DIR)'
    '    set(MAADEPS_DIR ${MAAUTILS_DIR}/MaaDeps)'
    'endif()'
    '# The super-project may provide its own CMake adapter (e.g. a repo-local'
    '# prebuilt deps/ tree) while MaaDeps is not present.'
    'if(DEFINED MAA_DEPS_CONFIG AND EXISTS "${MAA_DEPS_CONFIG}")'
    '    include(${MAA_DEPS_CONFIG})'
    'else()'
    '    include(${MAADEPS_DIR}/maadeps.cmake)'
    'endif()'
) -join "`n"
$content = $content.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
[System.IO.File]::WriteAllText($maaUtilsCmake, $content, (New-Object System.Text.UTF8Encoding($false)))
if (-not ([System.IO.File]::ReadAllText($maaUtilsCmake).Contains('MAA_DEPS_CONFIG'))) {
    throw "Failed to inject MAA_DEPS_CONFIG into $maaUtilsCmake"
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

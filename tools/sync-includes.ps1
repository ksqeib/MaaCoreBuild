param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$SourceRoot = "",
    [switch]$SyncUpstream,
    [switch]$Sync3rd
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host "==> $Name"
    & $Action
}

function Resolve-DefaultSourceRoot {
    param([string]$CurrentRepoRoot)

    $candidates = @(
        "D:\self\maa\MaaAssistantArknights",
        (Join-Path (Split-Path $CurrentRepoRoot -Parent) "MaaAssistantArknights"),
        (Join-Path $CurrentRepoRoot "_upstream")
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if ((Test-Path (Join-Path $candidate "include")) -and (Test-Path (Join-Path $candidate "3rdparty\include"))) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "Cannot auto-detect source root. Please pass -SourceRoot explicitly."
}

if (-not $SyncUpstream -and -not $Sync3rd) {
    $SyncUpstream = $true
    $Sync3rd = $true
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Resolve-DefaultSourceRoot -CurrentRepoRoot $RepoRoot
}
else {
    $SourceRoot = (Resolve-Path $SourceRoot).Path
}

$srcUpstream = Join-Path $SourceRoot "include"
$src3rd = Join-Path $SourceRoot "3rdparty\include"
$dstUpstream = Join-Path $RepoRoot "include\upstream"
$dst3rd = Join-Path $RepoRoot "include\3rd"

Invoke-Step "Validate source tree" {
    if ($SyncUpstream -and -not (Test-Path $srcUpstream)) {
        throw "Missing source include path: $srcUpstream"
    }

    if ($Sync3rd -and -not (Test-Path $src3rd)) {
        throw "Missing source 3rdparty include path: $src3rd"
    }
}

if ($SyncUpstream) {
    Invoke-Step "Sync include/upstream" {
        New-Item -ItemType Directory -Path $dstUpstream -Force | Out-Null
        Remove-Item -Path (Join-Path $dstUpstream "*") -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path (Join-Path $srcUpstream "*") -Destination $dstUpstream -Recurse -Force
    }
}

if ($Sync3rd) {
    Invoke-Step "Sync include/3rd" {
        New-Item -ItemType Directory -Path $dst3rd -Force | Out-Null
        Remove-Item -Path (Join-Path $dst3rd "*") -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path (Join-Path $src3rd "*") -Destination $dst3rd -Recurse -Force
    }
}

Write-Host ""
Write-Host "Include sync completed."
Write-Host "Source: $SourceRoot"
if ($SyncUpstream) {
    Write-Host "- Updated: $dstUpstream"
}
if ($Sync3rd) {
    Write-Host "- Updated: $dst3rd"
}


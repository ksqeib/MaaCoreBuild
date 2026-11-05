param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$DepsTarget = "",
    [switch]$ReleaseOnly = $true,
    [switch]$ForceDepsDownload
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

Invoke-Step "Validate local headers" {
    $requiredPaths = @(
        (Join-Path $RepoRoot "include\upstream\AsstCaller.h"),
        (Join-Path $RepoRoot "include\upstream\AsstCallerExtra.h"),
        (Join-Path $RepoRoot "include\upstream\AsstPort.h"),
        (Join-Path $RepoRoot "include\3rd\calculator\calculator.hpp"),
        (Join-Path $RepoRoot "include\3rd\zlib\decompress.hpp"),
        (Join-Path $RepoRoot "include\3rd\Arknights-Tile-Pos\TileCalc2.hpp")
    )

    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path $requiredPath)) {
            throw "Missing required header: $requiredPath"
        }
    }
}

Invoke-Step "Ensure prebuilt dependencies" {
    $fetchArgs = @{
        RepoRoot     = $RepoRoot
        ManifestPath = (Join-Path $PSScriptRoot "fastdeploy-manifest.json")
        ReleaseOnly  = $ReleaseOnly
    }
    if (-not [string]::IsNullOrWhiteSpace($DepsTarget)) {
        $fetchArgs.Target = $DepsTarget
    }
    if ($ForceDepsDownload) {
        $fetchArgs.Force = $true
    }

    & (Join-Path $PSScriptRoot "fetch-deps.ps1") @fetchArgs

    $requiredPaths = @(
        (Join-Path $RepoRoot "deps\include"),
        (Join-Path $RepoRoot "deps\lib"),
        (Join-Path $RepoRoot "deps\share"),
        (Join-Path $RepoRoot "deps\runtime\maa-x64-windows")
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path $requiredPath)) {
            throw "Dependency bundle is incomplete, missing: $requiredPath"
        }
    }
}

Write-Host ""
Write-Host "Standalone prerequisites are ready."
Write-Host "Build with:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\tools\build-maacore-only.ps1 -SkipBootstrap -UseSccache -NoFresh"


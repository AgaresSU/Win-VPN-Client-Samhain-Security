param(
    [string]$PackagePath = "",
    [switch]$StartService
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $PackagePath = Join-Path $repoRoot "dist\SamhainSecurity-0.3.8-win-x64"
}

$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$servicePath = Join-Path $packageFullPath "service\SamhainSecurity.Service.exe"

if (-not (Test-Path -LiteralPath $servicePath)) {
    throw "Service executable not found: $servicePath"
}

& $servicePath install

if ($StartService) {
    & $servicePath start
}

Write-Host "Samhain Security service prepared from $packageFullPath"

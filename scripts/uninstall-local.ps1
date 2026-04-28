param(
    [string]$PackagePath = "",
    [switch]$RemoveShortcut,
    [switch]$DisableStartup
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $PackagePath = Join-Path $repoRoot "dist\SamhainSecurity-0.4.9-win-x64"
}

$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$servicePath = Join-Path $packageFullPath "service\SamhainSecurity.Service.exe"

if (-not (Test-Path -LiteralPath $servicePath)) {
    throw "Service executable not found: $servicePath"
}

& $servicePath stop
& $servicePath uninstall

if ($RemoveShortcut) {
    $shortcutPath = Join-Path ([Environment]::GetFolderPath("Programs")) "Samhain Security.lnk"
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Start Menu shortcut removed"
    }
}

if ($DisableStartup) {
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runPath -Name "Samhain Security" -ErrorAction SilentlyContinue
    Write-Host "Per-user startup entry disabled"
}

Write-Host "Samhain Security service removed"

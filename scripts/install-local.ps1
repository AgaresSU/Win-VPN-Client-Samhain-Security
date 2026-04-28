param(
    [string]$PackagePath = "",
    [switch]$StartService,
    [switch]$CreateStartMenuShortcut,
    [switch]$EnableStartup
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $PackagePath = Join-Path $repoRoot "dist\SamhainSecurity-0.4.9-win-x64"
}

$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$servicePath = Join-Path $packageFullPath "service\SamhainSecurity.Service.exe"
$appPath = Join-Path $packageFullPath "app\SamhainSecurity.exe"

if (-not (Test-Path -LiteralPath $servicePath)) {
    throw "Service executable not found: $servicePath"
}

if (-not (Test-Path -LiteralPath $appPath)) {
    throw "Desktop executable not found: $appPath"
}

& $servicePath install

if ($StartService) {
    & $servicePath start
}

if ($CreateStartMenuShortcut) {
    $programs = [Environment]::GetFolderPath("Programs")
    $shortcutPath = Join-Path $programs "Samhain Security.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $appPath
    $shortcut.WorkingDirectory = Split-Path -Parent $appPath
    $shortcut.Description = "Samhain Security"
    $shortcut.Save()
    Write-Host "Start Menu shortcut: $shortcutPath"
}

if ($EnableStartup) {
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runPath -Force | Out-Null
    Set-ItemProperty -Path $runPath -Name "Samhain Security" -Value "`"$appPath`""
    Write-Host "Per-user startup entry enabled"
}

Write-Host "Samhain Security service prepared from $packageFullPath"

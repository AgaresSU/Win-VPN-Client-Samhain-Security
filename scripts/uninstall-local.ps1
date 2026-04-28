param(
    [string]$InstallRoot = "",
    [string]$PackagePath = "",
    [switch]$RemoveShortcut,
    [switch]$DisableStartup,
    [switch]$RemoveInstallFiles
)

$ErrorActionPreference = "Stop"
$Version = "0.5.0"
$ServiceName = "SamhainSecurity.Service"
$ProductName = "Samhain Security"

function Get-RepoRoot {
    return Resolve-Path (Join-Path $PSScriptRoot "..")
}

function Get-DefaultInstallRoot {
    $programFiles = [Environment]::GetFolderPath("ProgramFiles")
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = Join-Path $env:LOCALAPPDATA "Programs"
    }

    return Join-Path $programFiles $ProductName
}

function Assert-InstallRootForRemoval {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -eq $root) {
        throw "Refusing to remove filesystem root: $fullPath"
    }

    $leaf = Split-Path -Leaf $fullPath
    if ($leaf -notin @($ProductName, "SamhainSecurity")) {
        throw "Refusing to remove unexpected install root: $fullPath"
    }
}

function Test-ServiceInstalled {
    & sc.exe query $ServiceName *> $null
    return $LASTEXITCODE -eq 0
}

function Stop-And-Remove-Service {
    if (-not (Test-ServiceInstalled)) {
        return
    }

    & sc.exe stop $ServiceName *> $null
    Start-Sleep -Seconds 2
    & sc.exe delete $ServiceName *> $null
    Start-Sleep -Seconds 1
}

if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
    $targetRoot = [System.IO.Path]::GetFullPath($PackagePath)
} elseif (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
    $targetRoot = [System.IO.Path]::GetFullPath($InstallRoot)
} else {
    $targetRoot = [System.IO.Path]::GetFullPath((Get-DefaultInstallRoot))
}

Stop-And-Remove-Service

if ($RemoveShortcut) {
    $shortcutPaths = @(
        (Join-Path ([Environment]::GetFolderPath("Programs")) "$ProductName.lnk"),
        (Join-Path ([Environment]::GetFolderPath("DesktopDirectory")) "$ProductName.lnk")
    )

    foreach ($shortcutPath in $shortcutPaths) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Host "Shortcut removed: $shortcutPath"
        }
    }
}

if ($DisableStartup) {
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runPath -Name $ProductName -ErrorAction SilentlyContinue
    Write-Host "Per-user startup entry disabled"
}

if ($RemoveInstallFiles) {
    if (Test-Path -LiteralPath $targetRoot) {
        Assert-InstallRootForRemoval -Path $targetRoot
        Remove-Item -LiteralPath $targetRoot -Recurse -Force
        Write-Host "Install files removed: $targetRoot"
    }
}

Write-Host "$ProductName service removed. User data under APPDATA\SamhainSecurity was preserved."

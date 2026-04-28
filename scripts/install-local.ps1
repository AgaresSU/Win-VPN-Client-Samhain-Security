param(
    [string]$PackagePath = "",
    [string]$InstallRoot = "",
    [switch]$InPlace,
    [switch]$StartService,
    [switch]$CreateStartMenuShortcut,
    [switch]$CreateDesktopShortcut,
    [switch]$EnableStartup,
    [switch]$NoService
)

$ErrorActionPreference = "Stop"
$Version = "0.5.6"
$ServiceName = "SamhainSecurity.Service"
$ProductName = "Samhain Security"

function Get-RepoRoot {
    return Resolve-Path (Join-Path $PSScriptRoot "..")
}

function Get-DefaultPackagePath {
    $repoRoot = Get-RepoRoot
    return Join-Path $repoRoot "dist\SamhainSecurity-$Version-win-x64"
}

function Get-DefaultInstallRoot {
    $programFiles = [Environment]::GetFolderPath("ProgramFiles")
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = Join-Path $env:LOCALAPPDATA "Programs"
    }

    return Join-Path $programFiles $ProductName
}

function Assert-DirectoryForRecursiveDelete {
    param(
        [string]$Path,
        [string]$ExpectedParent
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parentPath = [System.IO.Path]::GetFullPath($ExpectedParent)
    $root = [System.IO.Path]::GetPathRoot($fullPath)

    if ($fullPath -eq $root) {
        throw "Refusing to remove filesystem root: $fullPath"
    }

    if (-not $fullPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove outside expected parent: $fullPath"
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

function Copy-Package {
    param(
        [string]$Source,
        [string]$Destination
    )

    $sourceFullPath = [System.IO.Path]::GetFullPath($Source)
    $destinationFullPath = [System.IO.Path]::GetFullPath($Destination)
    $stagePath = Join-Path $destinationFullPath ".installing"

    if (-not (Test-Path -LiteralPath $sourceFullPath)) {
        throw "Package path not found: $sourceFullPath"
    }

    New-Item -ItemType Directory -Path $destinationFullPath -Force | Out-Null
    if (Test-Path -LiteralPath $stagePath) {
        Assert-DirectoryForRecursiveDelete -Path $stagePath -ExpectedParent $destinationFullPath
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceFullPath "*") -Destination $stagePath -Recurse -Force
    Copy-Item -Path (Join-Path $stagePath "*") -Destination $destinationFullPath -Recurse -Force
    Assert-DirectoryForRecursiveDelete -Path $stagePath -ExpectedParent $destinationFullPath
    Remove-Item -LiteralPath $stagePath -Recurse -Force
}

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath
    )

    $directory = Split-Path -Parent $ShortcutPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.Description = $ProductName
    $shortcut.Save()
}

function Get-PackageVersion {
    param([string]$Path)

    $manifestPath = Join-Path $Path "release-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $Version
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    return [string]$manifest.version
}

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Get-DefaultPackagePath
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-DefaultInstallRoot
}

$packageFullPath = [System.IO.Path]::GetFullPath($PackagePath)
$installRootFullPath = [System.IO.Path]::GetFullPath($InstallRoot)

if (-not $InPlace) {
    Stop-And-Remove-Service
    Copy-Package -Source $packageFullPath -Destination $installRootFullPath
    $effectiveRoot = $installRootFullPath
} else {
    $effectiveRoot = $packageFullPath
}

$servicePath = Join-Path $effectiveRoot "service\SamhainSecurity.Service.exe"
$appPath = Join-Path $effectiveRoot "app\SamhainSecurity.exe"

if (-not (Test-Path -LiteralPath $servicePath)) {
    throw "Service executable not found: $servicePath"
}

if (-not (Test-Path -LiteralPath $appPath)) {
    throw "Desktop executable not found: $appPath"
}

if (-not $NoService) {
    if ($InPlace) {
        Stop-And-Remove-Service
    }

    & $servicePath install
    if ($StartService) {
        & $servicePath start
    }
}

$startMenuShortcut = ""
$desktopShortcut = ""

if ($CreateStartMenuShortcut) {
    $startMenuShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "$ProductName.lnk"
    New-Shortcut -ShortcutPath $startMenuShortcut -TargetPath $appPath
    Write-Host "Start Menu shortcut: $startMenuShortcut"
}

if ($CreateDesktopShortcut) {
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("DesktopDirectory")) "$ProductName.lnk"
    New-Shortcut -ShortcutPath $desktopShortcut -TargetPath $appPath
    Write-Host "Desktop shortcut: $desktopShortcut"
}

if ($EnableStartup) {
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runPath -Force | Out-Null
    Set-ItemProperty -Path $runPath -Name $ProductName -Value "`"$appPath`""
    Write-Host "Per-user startup entry enabled"
}

$installedVersion = Get-PackageVersion -Path $effectiveRoot
$installManifest = [PSCustomObject]@{
    product = $ProductName
    version = $installedVersion
    installedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    sourcePackage = $packageFullPath
    installRoot = $effectiveRoot
    appPath = $appPath
    servicePath = $servicePath
    servicePrepared = -not $NoService
    serviceStarted = [bool]$StartService
    startMenuShortcut = $startMenuShortcut
    desktopShortcut = $desktopShortcut
    startupEnabled = [bool]$EnableStartup
}

$installManifest |
    ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $effectiveRoot "install-manifest.json") -Encoding UTF8

Write-Host "$ProductName $installedVersion installed at $effectiveRoot"

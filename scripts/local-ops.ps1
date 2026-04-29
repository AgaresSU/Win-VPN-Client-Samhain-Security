param(
    [ValidateSet("Install", "Repair", "Uninstall", "Status")]
    [string]$Action = "Status",
    [string]$PackageRoot = "",
    [string]$InstallRoot = "",
    [switch]$RemoveData,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProductName = "Samhain Security"
$RunValueName = "Samhain Security"
$TaskName = "Samhain Security Service"
$UrlScheme = "samhain"
$DataRoot = Join-Path $env:APPDATA "SamhainSecurity"

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA "SamhainSecurity"
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $PackageRoot = Resolve-Path (Join-Path $scriptDir "..") -ErrorAction SilentlyContinue
    if (-not $PackageRoot) {
        $PackageRoot = Resolve-Path "." -ErrorAction Stop
    }
}

$PackageRoot = [System.IO.Path]::GetFullPath([string]$PackageRoot)
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$DataRoot = [System.IO.Path]::GetFullPath($DataRoot)

function Write-Step {
    param([string]$Message)
    Write-Host "[$ProductName] $Message"
}

function Invoke-Operation {
    param(
        [string]$Message,
        [scriptblock]$Operation
    )

    if ($DryRun) {
        Write-Step "DRY-RUN: $Message"
        return
    }

    Write-Step $Message
    & $Operation
}

function Assert-UserPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $local = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA)
    $roaming = [System.IO.Path]::GetFullPath($env:APPDATA)
    if (-not $fullPath.StartsWith($local, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($roaming, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside user profile data roots: $fullPath"
    }
}

function Test-PackageRoot {
    $missing = @()
    foreach ($relative in @("app\SamhainSecurityNative.exe", "service\samhain-service.exe", "VERSION")) {
        $path = Join-Path $PackageRoot $relative
        if (-not (Test-Path $path)) {
            $missing += $relative
        }
    }

    if ($missing.Count -gt 0) {
        $message = "Package is incomplete in $PackageRoot. Missing: $($missing -join ', ')"
        if ($DryRun) {
            Write-Step "DRY-RUN: $message"
            return
        }

        throw $message
    }
}

function Get-InstalledVersion {
    $versionFile = Join-Path $InstallRoot "VERSION"
    if (Test-Path $versionFile) {
        return (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    return ""
}

function Stop-InstalledProcesses {
    foreach ($name in @("SamhainSecurityNative", "samhain-service")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($InstallRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $processId = $_.Id
                Invoke-Operation "Stopping $name ($processId)" { Stop-Process -Id $processId -Force }
            }
        }
    }
}

function Copy-PackageContent {
    Test-PackageRoot
    Assert-UserPath $InstallRoot

    Invoke-Operation "Creating install root $InstallRoot" {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    foreach ($entry in @("app", "service", "assets", "docs")) {
        $source = Join-Path $PackageRoot $entry
        $target = Join-Path $InstallRoot $entry
        if (Test-Path $source) {
            Invoke-Operation "Refreshing $entry" {
                if (Test-Path $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                }
                Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
            }
        }
    }

    foreach ($file in @("README.md", "VERSION", "release-manifest.json", "checksums.txt")) {
        $source = Join-Path $PackageRoot $file
        if (Test-Path $source) {
            Invoke-Operation "Copying $file" {
                Copy-Item -LiteralPath $source -Destination (Join-Path $InstallRoot $file) -Force
            }
        }
    }

    Invoke-Operation "Writing install-state.json" {
        [PSCustomObject]@{
            product = $ProductName
            version = Get-InstalledVersion
            installRoot = $InstallRoot
            dataRoot = $DataRoot
            packageRoot = $PackageRoot
            scope = "CurrentUser"
            installedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallRoot "install-state.json") -Encoding UTF8
    }
}

function Register-Autostart {
    $appExe = Join-Path $InstallRoot "app\SamhainSecurityNative.exe"
    $command = '"' + $appExe + '" --background'
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Invoke-Operation "Registering user autostart" {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -Path $runKey -Name $RunValueName -Value $command -PropertyType String -Force | Out-Null
    }
}

function Register-UrlScheme {
    $appExe = Join-Path $InstallRoot "app\SamhainSecurityNative.exe"
    $root = "HKCU:\Software\Classes\$UrlScheme"
    $icon = "$root\DefaultIcon"
    $commandKey = "$root\shell\open\command"
    $command = '"' + $appExe + '" "%1"'
    Invoke-Operation "Registering ${UrlScheme}:// handler" {
        New-Item -Path $root -Force | Out-Null
        Set-Item -Path $root -Value "URL:$ProductName"
        New-ItemProperty -Path $root -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null
        New-Item -Path $icon -Force | Out-Null
        Set-Item -Path $icon -Value $appExe
        New-Item -Path $commandKey -Force | Out-Null
        Set-Item -Path $commandKey -Value $command
    }
}

function Register-ServiceTask {
    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    $taskCommand = '"' + $serviceExe + '" run'
    Invoke-Operation "Registering user service task" {
        & schtasks.exe /Create /F /TN $TaskName /SC ONLOGON /TR $taskCommand | Out-Null
    }
}

function Start-LocalService {
    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    Invoke-Operation "Starting local service process" {
        Start-Process -FilePath $serviceExe -ArgumentList "run" -WindowStyle Hidden | Out-Null
    }
}

function Invoke-StateMigration {
    Assert-UserPath $DataRoot
    $migrationRoot = Join-Path $DataRoot "migration"
    $legacyCandidates = @(
        (Join-Path $env:APPDATA "Samhain Security"),
        (Join-Path $env:APPDATA "SamhainSecurityNative"),
        (Join-Path $env:LOCALAPPDATA "Samhain Security"),
        (Join-Path $env:LOCALAPPDATA "SamhainSecurityNative")
    )

    Invoke-Operation "Preparing migration backup folder" {
        New-Item -ItemType Directory -Force -Path $migrationRoot | Out-Null
    }

    foreach ($candidate in $legacyCandidates) {
        if (Test-Path $candidate) {
            $leaf = Split-Path -Leaf $candidate
            $target = Join-Path $migrationRoot $leaf
            Invoke-Operation "Backing up legacy state from $candidate" {
                Copy-Item -LiteralPath $candidate -Destination $target -Recurse -Force
            }
        }
    }
}

function Unregister-LocalIntegration {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Invoke-Operation "Removing user autostart" {
        Remove-ItemProperty -Path $runKey -Name $RunValueName -ErrorAction SilentlyContinue
    }

    Invoke-Operation "Removing ${UrlScheme}:// handler" {
        Remove-Item -Path "HKCU:\Software\Classes\$UrlScheme" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-Operation "Removing user service task" {
        & schtasks.exe /Delete /F /TN $TaskName 2>$null | Out-Null
    }
}

function Remove-InstallRoot {
    Assert-UserPath $InstallRoot
    Invoke-Operation "Removing install root $InstallRoot" {
        if (Test-Path $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
    }
}

function Remove-DataRoot {
    Assert-UserPath $DataRoot
    Invoke-Operation "Removing data root $DataRoot" {
        if (Test-Path $DataRoot) {
            Remove-Item -LiteralPath $DataRoot -Recurse -Force
        }
    }
}

function Get-LocalStatus {
    $appExe = Join-Path $InstallRoot "app\SamhainSecurityNative.exe"
    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    $taskExists = $false
    & schtasks.exe /Query /TN $TaskName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $taskExists = $true
    }

    [PSCustomObject]@{
        product = $ProductName
        installed = (Test-Path $appExe) -and (Test-Path $serviceExe)
        version = Get-InstalledVersion
        installRoot = $InstallRoot
        dataRoot = $DataRoot
        userServiceTask = $taskExists
        autostart = [bool](Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $RunValueName -ErrorAction SilentlyContinue)
        urlScheme = Test-Path "HKCU:\Software\Classes\$UrlScheme"
        dryRun = [bool]$DryRun
    }
}

switch ($Action) {
    "Install" {
        Copy-PackageContent
        Invoke-StateMigration
        Register-Autostart
        Register-UrlScheme
        Register-ServiceTask
        Start-LocalService
        Get-LocalStatus | ConvertTo-Json -Depth 4
    }
    "Repair" {
        Stop-InstalledProcesses
        Copy-PackageContent
        Register-Autostart
        Register-UrlScheme
        Register-ServiceTask
        Start-LocalService
        Get-LocalStatus | ConvertTo-Json -Depth 4
    }
    "Uninstall" {
        Stop-InstalledProcesses
        Unregister-LocalIntegration
        Remove-InstallRoot
        if ($RemoveData) {
            Remove-DataRoot
        }
        Get-LocalStatus | ConvertTo-Json -Depth 4
    }
    "Status" {
        Get-LocalStatus | ConvertTo-Json -Depth 4
    }
}

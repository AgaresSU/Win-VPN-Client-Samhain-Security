param(
    [ValidateSet("Install", "Repair", "Uninstall", "Status")]
    [string]$Action = "Status",
    [ValidateSet("CurrentUser", "Machine")]
    [string]$Scope = "CurrentUser",
    [string]$PackageRoot = "",
    [string]$InstallRoot = "",
    [switch]$RemoveData,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProductName = "Samhain Security"
$RunValueName = "Samhain Security"
$AutostartArguments = "--background"
$TaskName = "Samhain Security Service"
$ServiceName = "SamhainSecurityService"
$ServiceDisplayName = "Samhain Security Service"
$ServiceDescription = "Samhain Security privileged network service"
$UrlScheme = "samhain"
$DataRoot = if ($Scope -eq "Machine") {
    Join-Path $env:ProgramData "SamhainSecurity"
}
else {
    Join-Path $env:APPDATA "SamhainSecurity"
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    if ($Scope -eq "Machine") {
        $InstallRoot = Join-Path $env:ProgramFiles "SamhainSecurity"
    }
    else {
        $InstallRoot = Join-Path $env:LOCALAPPDATA "SamhainSecurity"
    }
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

function Assert-UnderPath {
    param(
        [string]$Path,
        [string]$Root,
        [string]$Label
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify $Label outside $fullRoot`: $fullPath"
    }
}

function Assert-MachinePath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) }

    if (-not ($roots | Where-Object { $fullPath.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })) {
        throw "Refusing to modify machine install path outside Program Files: $fullPath"
    }
}

function Assert-MachineDataPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $programData = [System.IO.Path]::GetFullPath($env:ProgramData)
    if (-not $fullPath.StartsWith($programData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify machine data path outside ProgramData: $fullPath"
    }
}

function Get-AppExecutablePath {
    Join-Path $InstallRoot "app\SamhainSecurityNative.exe"
}

function Get-ServiceExecutablePath {
    Join-Path $InstallRoot "service\samhain-service.exe"
}

function Get-ExpectedAutostartCommand {
    $appExe = Get-AppExecutablePath
    '"' + $appExe + '" ' + $AutostartArguments
}

function Get-ExpectedUrlCommand {
    $appExe = Get-AppExecutablePath
    '"' + $appExe + '" "%1"'
}

function Get-RegistryDefaultValue {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return ""
    }

    $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        return ""
    }

    return [string]$item.GetValue("")
}

function Get-RegistryNamedValue {
    param(
        [string]$Path,
        [string]$Name
    )

    $property = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $property) {
        return ""
    }

    $member = $property.PSObject.Properties[$Name]
    if (-not $member) {
        return ""
    }

    return [string]$member.Value
}

function Get-DesktopIntegrationStatus {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $schemeRoot = "HKCU:\Software\Classes\$UrlScheme"
    $iconKey = "$schemeRoot\DefaultIcon"
    $commandKey = "$schemeRoot\shell\open\command"
    $expectedAutostart = Get-ExpectedAutostartCommand
    $expectedUrlCommand = Get-ExpectedUrlCommand
    $appExe = Get-AppExecutablePath
    $actualAutostart = Get-RegistryNamedValue -Path $runKey -Name $RunValueName
    $actualSchemeName = Get-RegistryDefaultValue -Path $schemeRoot
    $actualUrlProtocol = Get-RegistryNamedValue -Path $schemeRoot -Name "URL Protocol"
    $actualIcon = Get-RegistryDefaultValue -Path $iconKey
    $actualCommand = Get-RegistryDefaultValue -Path $commandKey
    $autostartOwned = $actualAutostart -eq $expectedAutostart
    $urlSchemeOwned = (Test-Path $schemeRoot) `
        -and ($actualSchemeName -eq "URL:$ProductName") `
        -and ($actualUrlProtocol -eq "") `
        -and ($actualIcon -eq $appExe) `
        -and ($actualCommand -eq $expectedUrlCommand)
    $status = if ($autostartOwned -and $urlSchemeOwned) {
        "owned"
    }
    elseif ([string]::IsNullOrWhiteSpace($actualAutostart) -and -not (Test-Path $schemeRoot)) {
        "not-registered"
    }
    else {
        "drift"
    }

    [PSCustomObject]@{
        owner = "local-ops"
        status = $status
        runValueName = $RunValueName
        urlScheme = "${UrlScheme}://"
        expected = [PSCustomObject]@{
            autostartCommand = $expectedAutostart
            urlCommand = $expectedUrlCommand
            icon = $appExe
        }
        actual = [PSCustomObject]@{
            autostartCommand = $actualAutostart
            urlName = $actualSchemeName
            urlProtocol = $actualUrlProtocol
            icon = $actualIcon
            urlCommand = $actualCommand
        }
        autostartRegistered = -not [string]::IsNullOrWhiteSpace($actualAutostart)
        autostartOwned = $autostartOwned
        urlSchemeRegistered = Test-Path $schemeRoot
        urlSchemeOwned = $urlSchemeOwned
        evidence = @(
            "autostart-owner=local-ops",
            "url-scheme-owner=local-ops",
            "single-instance-handoff=desktop",
            "tray-owner=desktop"
        )
    }
}

function Test-UserServiceTask {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & schtasks.exe /Query /TN $TaskName *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Write-DesktopIntegrationState {
    Assert-UserPath $InstallRoot
    Invoke-Operation "Writing desktop-integration.json" {
        Get-DesktopIntegrationStatus |
            ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $InstallRoot "desktop-integration.json") -Encoding UTF8
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MachineServiceRecord {
    try {
        return Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-MachineServicePlan {
    param([string]$Operation)

    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    switch ($Operation) {
        "Install" {
            return @(
                "Verify package integrity and version metadata",
                "Copy app, service, assets, docs, and tools to $InstallRoot",
                "Register Windows service $ServiceName with command `"$serviceExe`" run",
                "Set service start mode to Automatic",
                "Set recovery policy to restart after failure",
                "Start service and verify named-pipe status",
                "Write install-state.json with scope=Machine"
            )
        }
        "Repair" {
            return @(
                "Stop service $ServiceName if it is running",
                "Refresh package files in $InstallRoot",
                "Reapply service command, start mode, and recovery policy",
                "Start service and verify named-pipe status",
                "Write repair timestamp to install-state.json"
            )
        }
        "Uninstall" {
            $dataAction = if ($RemoveData) { "Remove service data root $DataRoot" } else { "Preserve service data root $DataRoot" }
            return @(
                "Stop service $ServiceName if it is running",
                "Delete Windows service $ServiceName",
                "Remove install root $InstallRoot",
                $dataAction
            )
        }
        default {
            return @(
                "Inspect service $ServiceName",
                "Report install root, command path, start mode, status, and elevation"
            )
        }
    }
}

function Assert-MachineOperationSupported {
    param([string]$Operation)

    if ($Operation -eq "Status") {
        return
    }

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        throw "Machine scope $Operation requires an elevated PowerShell session."
    }
}

function Get-MachineStatus {
    $serviceRecord = Get-MachineServiceRecord
    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    $serviceInstalled = $null -ne $serviceRecord
    $status = if (-not $serviceInstalled) {
        "not-installed"
    }
    elseif ($serviceRecord.State -eq "Running") {
        "running"
    }
    else {
        "installed"
    }

    [PSCustomObject]@{
        product = $ProductName
        scope = "Machine"
        status = $status
        implemented = "installer-owned"
        installed = $serviceInstalled
        version = Get-InstalledVersion
        serviceName = $ServiceName
        serviceDisplayName = $ServiceDisplayName
        serviceDescription = $ServiceDescription
        serviceStatus = if ($serviceRecord) { [string]$serviceRecord.State } else { "missing" }
        startMode = if ($serviceRecord) { [string]$serviceRecord.StartMode } else { "not-registered" }
        executable = $serviceExe
        registeredPath = if ($serviceRecord) { [string]$serviceRecord.PathName } else { "" }
        desktopIntegrationPolicy = "per-user"
        desktopIntegrationOwner = "current-user local-ops or desktop settings"
        installRoot = $InstallRoot
        dataRoot = $DataRoot
        administrator = Test-IsAdministrator
        dryRun = [bool]$DryRun
        writeOperationsAvailable = Test-IsAdministrator
        plannedActions = Get-MachineServicePlan -Operation $Action
    }
}

function Invoke-ScCommand {
    param(
        [string]$Message,
        [string[]]$Arguments
    )

    Invoke-Operation $Message {
        $output = & sc.exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "sc.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE`: $($output | Out-String)"
        }
    }
}

function Wait-MachineServiceState {
    param(
        [string]$TargetState,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status.ToString() -eq $TargetState) {
            return $true
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-MachineService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    if ($service.Status -ne "Stopped") {
        Invoke-Operation "Stopping machine service $ServiceName" {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            if (-not (Wait-MachineServiceState -TargetState "Stopped")) {
                throw "Timed out waiting for $ServiceName to stop."
            }
        }
    }
}

function Copy-MachinePackageContent {
    Test-PackageRoot
    Assert-MachinePath $InstallRoot

    Invoke-Operation "Creating machine install root $InstallRoot" {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    foreach ($entry in @("app", "service", "assets", "docs", "tools")) {
        $source = Join-Path $PackageRoot $entry
        $target = Join-Path $InstallRoot $entry
        Assert-UnderPath -Path $target -Root $InstallRoot -Label "machine package content"
        if (Test-Path $source) {
            Invoke-Operation "Refreshing machine $entry" {
                if (Test-Path $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force
                }
                Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
            }
        }
    }

    foreach ($file in @("README.md", "VERSION", "release-manifest.json", "checksums.txt")) {
        $source = Join-Path $PackageRoot $file
        $target = Join-Path $InstallRoot $file
        Assert-UnderPath -Path $target -Root $InstallRoot -Label "machine package file"
        if (Test-Path $source) {
            Invoke-Operation "Copying machine $file" {
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
        }
    }
}

function Register-MachineService {
    $serviceExe = Join-Path $InstallRoot "service\samhain-service.exe"
    if (-not $DryRun -and -not (Test-Path $serviceExe)) {
        throw "Machine service executable is missing: $serviceExe"
    }

    $binaryPath = "`"$serviceExe`" run"
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Invoke-ScCommand "Updating Windows service $ServiceName" @(
            "config",
            $ServiceName,
            "binPath=",
            $binaryPath,
            "start=",
            "auto",
            "DisplayName=",
            $ServiceDisplayName
        )
        Invoke-ScCommand "Updating Windows service description" @(
            "description",
            $ServiceName,
            $ServiceDescription
        )
    }
    else {
        Invoke-Operation "Registering Windows service $ServiceName" {
            New-Service `
                -Name $ServiceName `
                -BinaryPathName $binaryPath `
                -DisplayName $ServiceDisplayName `
                -Description $ServiceDescription `
                -StartupType Automatic | Out-Null
        }
    }
}

function Set-MachineServiceRecovery {
    Invoke-ScCommand "Configuring Windows service recovery policy" @(
        "failure",
        $ServiceName,
        "reset=",
        "86400",
        "actions=",
        "restart/5000/restart/30000/restart/60000"
    )
    Invoke-ScCommand "Enabling service failure flag" @(
        "failureflag",
        $ServiceName,
        "1"
    )
}

function Start-MachineService {
    Invoke-Operation "Starting machine service $ServiceName" {
        Start-Service -Name $ServiceName -ErrorAction Stop
        if (-not (Wait-MachineServiceState -TargetState "Running")) {
            throw "Timed out waiting for $ServiceName to run."
        }
    }
}

function Write-MachineInstallState {
    Assert-MachinePath $InstallRoot
    Invoke-Operation "Writing machine install-state.json" {
        [PSCustomObject]@{
            product = $ProductName
            version = Get-InstalledVersion
            installRoot = $InstallRoot
            dataRoot = $DataRoot
            packageRoot = $PackageRoot
            scope = "Machine"
            serviceName = $ServiceName
            repairedAtUtc = if ($Action -eq "Repair") { (Get-Date).ToUniversalTime().ToString("O") } else { $null }
            installedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallRoot "install-state.json") -Encoding UTF8
    }
}

function Remove-MachineInstallRoot {
    Assert-MachinePath $InstallRoot
    Invoke-Operation "Removing machine install root $InstallRoot" {
        if (Test-Path $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
    }
}

function Remove-MachineDataRoot {
    Assert-MachineDataPath $DataRoot
    Invoke-Operation "Removing machine data root $DataRoot" {
        if (Test-Path $DataRoot) {
            Remove-Item -LiteralPath $DataRoot -Recurse -Force
        }
    }
}

function Unregister-MachineService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        return
    }

    Stop-MachineService
    Invoke-ScCommand "Deleting Windows service $ServiceName" @("delete", $ServiceName)
}

function Invoke-MachineInstall {
    $serviceExisted = $null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
    $rootExisted = Test-Path $InstallRoot

    try {
        Copy-MachinePackageContent
        Register-MachineService
        Set-MachineServiceRecovery
        Write-MachineInstallState
        Start-MachineService
    }
    catch {
        Write-Step "Machine install failed: $($_.Exception.Message)"
        if (-not $serviceExisted) {
            try { Unregister-MachineService } catch { Write-Step "Rollback service cleanup failed: $($_.Exception.Message)" }
        }
        if (-not $rootExisted) {
            try { Remove-MachineInstallRoot } catch { Write-Step "Rollback install-root cleanup failed: $($_.Exception.Message)" }
        }
        throw
    }

    Get-MachineStatus
}

function Invoke-MachineRepair {
    Stop-MachineService
    Copy-MachinePackageContent
    Register-MachineService
    Set-MachineServiceRecovery
    Write-MachineInstallState
    Start-MachineService
    Get-MachineStatus
}

function Invoke-MachineUninstall {
    Unregister-MachineService
    Remove-MachineInstallRoot
    if ($RemoveData) {
        Remove-MachineDataRoot
    }
    Get-MachineStatus
}

function Invoke-MachineOperation {
    param([string]$Operation)

    Assert-MachineOperationSupported $Operation

    if ($DryRun -and $Operation -in @("Install", "Repair")) {
        Test-PackageRoot
    }

    if ($DryRun) {
        foreach ($step in (Get-MachineServicePlan -Operation $Operation)) {
            Invoke-Operation "Machine scope: $step" {}
        }
        return Get-MachineStatus
    }

    switch ($Operation) {
        "Install" { return (Invoke-MachineInstall) }
        "Repair" { return (Invoke-MachineRepair) }
        "Uninstall" { return (Invoke-MachineUninstall) }
        default { return (Get-MachineStatus) }
    }
}

function Copy-PackageContent {
    Test-PackageRoot
    Assert-UserPath $InstallRoot

    Invoke-Operation "Creating install root $InstallRoot" {
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    }

    foreach ($entry in @("app", "service", "assets", "docs", "tools")) {
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
    $command = Get-ExpectedAutostartCommand
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Invoke-Operation "Registering user autostart" {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -Path $runKey -Name $RunValueName -Value $command -PropertyType String -Force | Out-Null
    }
}

function Register-UrlScheme {
    $appExe = Get-AppExecutablePath
    $root = "HKCU:\Software\Classes\$UrlScheme"
    $icon = "$root\DefaultIcon"
    $commandKey = "$root\shell\open\command"
    $command = Get-ExpectedUrlCommand
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
    $serviceExe = Get-ServiceExecutablePath
    $taskCommand = '"' + $serviceExe + '" run'
    Invoke-Operation "Registering user service task" {
        & schtasks.exe /Create /F /TN $TaskName /SC ONLOGON /TR $taskCommand | Out-Null
    }
}

function Start-LocalService {
    $serviceExe = Get-ServiceExecutablePath
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
    $appExe = Get-AppExecutablePath
    $serviceExe = Get-ServiceExecutablePath
    $taskExists = Test-UserServiceTask
    $desktopIntegration = Get-DesktopIntegrationStatus

    [PSCustomObject]@{
        product = $ProductName
        scope = "CurrentUser"
        installed = (Test-Path $appExe) -and (Test-Path $serviceExe)
        version = Get-InstalledVersion
        installRoot = $InstallRoot
        dataRoot = $DataRoot
        userServiceTask = $taskExists
        autostart = $desktopIntegration.autostartRegistered
        autostartOwned = $desktopIntegration.autostartOwned
        urlScheme = $desktopIntegration.urlSchemeRegistered
        urlSchemeOwned = $desktopIntegration.urlSchemeOwned
        desktopIntegration = $desktopIntegration
        dryRun = [bool]$DryRun
    }
}

if ($Scope -eq "Machine") {
    switch ($Action) {
        "Install" {
            Invoke-MachineOperation -Operation "Install" | ConvertTo-Json -Depth 5
        }
        "Repair" {
            Invoke-MachineOperation -Operation "Repair" | ConvertTo-Json -Depth 5
        }
        "Uninstall" {
            Invoke-MachineOperation -Operation "Uninstall" | ConvertTo-Json -Depth 5
        }
        "Status" {
            Get-MachineStatus | ConvertTo-Json -Depth 5
        }
    }

    exit 0
}

switch ($Action) {
    "Install" {
        Copy-PackageContent
        Invoke-StateMigration
        Register-Autostart
        Register-UrlScheme
        Write-DesktopIntegrationState
        Register-ServiceTask
        Start-LocalService
        Get-LocalStatus | ConvertTo-Json -Depth 4
    }
    "Repair" {
        Stop-InstalledProcesses
        Copy-PackageContent
        Register-Autostart
        Register-UrlScheme
        Write-DesktopIntegrationState
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

exit 0

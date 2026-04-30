param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [switch]$RequireMachineInstalled,
    [switch]$RequireProductionSigned,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Resolve-PackageRoot {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return [System.IO.Path]::GetFullPath((Resolve-Path $Value -ErrorAction Stop))
    }

    $scriptDir = Split-Path -Parent $PSCommandPath
    if ((Split-Path -Leaf $scriptDir) -eq "tools") {
        return [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $scriptDir "..") -ErrorAction Stop))
    }

    $repoRoot = Resolve-Path (Join-Path $scriptDir "..") -ErrorAction Stop
    $distRoot = Join-Path $repoRoot "dist"
    $latest = Get-ChildItem -Path $distRoot -Directory -Filter "SamhainSecurityNative-*-win-x64" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "Package root was not supplied and no package was found in $distRoot"
    }

    return [System.IO.Path]::GetFullPath($latest.FullName)
}

function Add-Check {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    if (-not $Ok) {
        $script:failed = $true
    }

    $script:checks.Add([PSCustomObject]@{
        name = $Name
        ok = $Ok
        detail = $Detail
    }) | Out-Null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceRecord {
    param([string]$ServiceName)

    try {
        return Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-PathStartsWith {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}

$checks = New-Object System.Collections.Generic.List[object]
$failed = $false
$warnings = New-Object System.Collections.Generic.List[string]
$packageVersion = ""
$manifest = $null
$manifestPath = Join-Path $PackageRoot "release-manifest.json"
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
$localOps = Join-Path $PackageRoot "tools\local-ops.ps1"
$defaultInstallRoot = Join-Path $env:ProgramFiles "SamhainSecurity"
$expectedMachineServiceExe = Join-Path $defaultInstallRoot "service\samhain-service.exe"
$serviceName = "SamhainSecurityService"

try {
    $packageVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}
catch {
    $packageVersion = ""
}

Add-Check "package:version" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
Add-Check "package:service-exe" (Test-Path -LiteralPath $serviceExe) $serviceExe
Add-Check "package:local-ops" (Test-Path -LiteralPath $localOps) $localOps
Add-Check "package:manifest" (Test-Path -LiteralPath $manifestPath) $manifestPath

if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $privilegedService = $manifest.operations.privilegedService
        Add-Check "manifest:privileged-service" ($privilegedService.status -eq "installer-owned") ([string]$privilegedService.status)
        Add-Check "manifest:service-name" ($privilegedService.serviceName -eq $serviceName) ([string]$privilegedService.serviceName)
        Add-Check "manifest:requires-elevation" ([bool]$privilegedService.requiresElevation) ([string]$privilegedService.requiresElevation)
        Add-Check "manifest:service-actions" (($privilegedService.actions -contains "Install") -and ($privilegedService.actions -contains "Repair") -and ($privilegedService.actions -contains "Uninstall")) "actions=$($privilegedService.actions -join ',')"
        Add-Check "manifest:readiness-script" ($manifest.quality.privilegedServiceReadinessScript -eq "tools\test-privileged-service-readiness.ps1") ([string]$manifest.quality.privilegedServiceReadinessScript)
    }
    catch {
        Add-Check "manifest:json" $false $_.Exception.Message
    }
}

if (Test-Path -LiteralPath $serviceExe) {
    $signature = Get-AuthenticodeSignature -LiteralPath $serviceExe
    $signatureValid = $signature.Status -eq "Valid"
    Add-Check "signature:service" ((-not $RequireProductionSigned) -or $signatureValid) "status=$($signature.Status)"
    if (-not $signatureValid) {
        $warnings.Add("Service binary is not production signed yet: $($signature.Status).") | Out-Null
    }
}

if (Test-Path -LiteralPath $localOps) {
    try {
        $statusOutput = & $localOps -Action Status -Scope Machine -PackageRoot $PackageRoot -DryRun 6>$null 2>&1
        $statusExitCode = $LASTEXITCODE
        $machineStatus = ($statusOutput | Out-String).Trim() | ConvertFrom-Json
        Add-Check "local-ops:machine-status" ($statusExitCode -eq 0 -and $machineStatus.scope -eq "Machine") "exit=$statusExitCode status=$($machineStatus.status)"
        Add-Check "local-ops:machine-plan" (@($machineStatus.plannedActions).Count -gt 0) "steps=$(@($machineStatus.plannedActions).Count)"
        Add-Check "local-ops:machine-install-root" (Test-PathStartsWith -Path ([string]$machineStatus.installRoot) -Root $env:ProgramFiles) ([string]$machineStatus.installRoot)
        Add-Check "local-ops:machine-data-root" (Test-PathStartsWith -Path ([string]$machineStatus.dataRoot) -Root $env:ProgramData) ([string]$machineStatus.dataRoot)
    }
    catch {
        Add-Check "local-ops:machine-status" $false $_.Exception.Message
    }

    try {
        $installDryRunOutput = & $localOps -Action Install -Scope Machine -PackageRoot $PackageRoot -DryRun 6>$null 2>&1
        $installDryRunExitCode = $LASTEXITCODE
        $installDryRun = ($installDryRunOutput | Out-String).Trim() | ConvertFrom-Json
        Add-Check "local-ops:machine-install-dry-run" ($installDryRunExitCode -eq 0 -and $installDryRun.scope -eq "Machine") "exit=$installDryRunExitCode status=$($installDryRun.status)"
        Add-Check "local-ops:machine-install-plan" (@($installDryRun.plannedActions).Count -ge 5) "steps=$(@($installDryRun.plannedActions).Count)"
    }
    catch {
        Add-Check "local-ops:machine-install-dry-run" $false $_.Exception.Message
    }
}

if (Test-Path -LiteralPath $serviceExe) {
    $previousStorage = $env:SAMHAIN_STORAGE_PATH
    try {
        $env:SAMHAIN_STORAGE_PATH = Join-Path $env:TEMP ("samhain-privileged-readiness-" + [guid]::NewGuid().ToString() + ".json")
        $serviceOutput = & $serviceExe status 2>&1
        $serviceExitCode = $LASTEXITCODE
        $serviceState = ($serviceOutput | Out-String).Trim() | ConvertFrom-Json
        $readiness = $serviceState.service_readiness
        Add-Check "service:status" ($serviceExitCode -eq 0 -and $serviceState.version -eq $ExpectedVersion) "exit=$serviceExitCode version=$($serviceState.version)"
        Add-Check "service:readiness-fields" (($null -ne $readiness) -and ($null -ne $readiness.privileged_service_ready) -and ($null -ne $readiness.tun_path_allowed) -and ($null -ne $readiness.adapter_path_allowed)) "status=$($readiness.status)"
        Add-Check "service:readiness-sources" ((-not [string]::IsNullOrWhiteSpace([string]$readiness.identity_source)) -and (-not [string]::IsNullOrWhiteSpace([string]$readiness.signing_source))) "identity=$($readiness.identity_source) signing=$($readiness.signing_source)"
        $currentPackageIsMachinePath = Test-PathStartsWith -Path $serviceExe -Root $env:ProgramFiles
        Add-Check "service:package-readiness-policy" (($currentPackageIsMachinePath) -or (-not [bool]$readiness.privileged_service_ready)) "machinePath=$currentPackageIsMachinePath ready=$($readiness.privileged_service_ready)"
        Add-Check "service:tun-field" ($null -ne $readiness.tun_path_allowed) "tun=$($readiness.tun_path_allowed)"
        Add-Check "service:adapter-field" ($null -ne $readiness.adapter_path_allowed) "adapter=$($readiness.adapter_path_allowed)"
    }
    catch {
        Add-Check "service:status" $false $_.Exception.Message
    }
    finally {
        if ($null -eq $previousStorage) {
            Remove-Item Env:\SAMHAIN_STORAGE_PATH -ErrorAction SilentlyContinue
        }
        else {
            $env:SAMHAIN_STORAGE_PATH = $previousStorage
        }
    }
}

$serviceRecord = Get-ServiceRecord -ServiceName $serviceName
$serviceInstalled = $null -ne $serviceRecord
Add-Check "machine:service-installed" (($serviceInstalled) -or (-not $RequireMachineInstalled)) "installed=$serviceInstalled"

if ($serviceInstalled) {
    $registeredPath = [string]$serviceRecord.PathName
    $pathOwned = $registeredPath -like "*$expectedMachineServiceExe*"
    Add-Check "machine:service-path" $pathOwned $registeredPath
    Add-Check "machine:service-start-mode" ($serviceRecord.StartMode -eq "Auto") ([string]$serviceRecord.StartMode)
    Add-Check "machine:service-state" ($serviceRecord.State -in @("Running", "Stopped")) ([string]$serviceRecord.State)
    Add-Check "machine:service-account" (-not [string]::IsNullOrWhiteSpace([string]$serviceRecord.StartName)) ([string]$serviceRecord.StartName)
}
else {
    $warnings.Add("Machine service is not installed yet; adapter and TUN paths remain gated outside dry-run checks.") | Out-Null
}

$administrator = Test-IsAdministrator
$readyForLivePrivilegedActions = $serviceInstalled -and $administrator -and (-not $RequireProductionSigned -or ($signatureValid -eq $true))

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    requireMachineInstalled = [bool]$RequireMachineInstalled
    requireProductionSigned = [bool]$RequireProductionSigned
    administrator = $administrator
    serviceInstalled = $serviceInstalled
    readyForLivePrivilegedActions = $readyForLivePrivilegedActions
    expectedMachineServiceExe = $expectedMachineServiceExe
    checks = $checks
    warnings = $warnings
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $checks | Format-Table -AutoSize
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:"
        $warnings | ForEach-Object { Write-Host "- $_" }
    }
}

if ($failed) {
    exit 1
}

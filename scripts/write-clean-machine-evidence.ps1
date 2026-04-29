param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$MatrixCase = "local-dev",
    [string]$Operator = $env:USERNAME,
    [switch]$SkipLaunch,
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

function Get-HostFacts {
    $osCaption = [System.Environment]::OSVersion.VersionString
    $osBuild = [System.Environment]::OSVersion.Version.ToString()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osCaption = [string]$os.Caption
        $osBuild = [string]$os.BuildNumber
    }
    catch {
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    [PSCustomObject]@{
        machineName = $env:COMPUTERNAME
        userName = $env:USERNAME
        operator = $Operator
        osCaption = $osCaption
        osBuild = $osBuild
        isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    }
}

function Add-Step {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    if (-not $Ok) {
        $script:failed = $true
    }

    $script:steps.Add([PSCustomObject]@{
        name = $Name
        ok = $Ok
        detail = $Detail
    }) | Out-Null
}

function Invoke-ScriptStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path $ScriptPath)) {
        Add-Step $Name $false "missing=$ScriptPath"
        return
    }

    try {
        $output = & $ScriptPath @Parameters *>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_ | Out-String
        $exitCode = 1
    }
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 700) {
        $detail = $detail.Substring(0, 700)
    }

    Add-Step $Name ($exitCode -eq 0) "exit=$exitCode $detail"
}

function Invoke-ExpectedFailureStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path $ScriptPath)) {
        Add-Step $Name $false "missing=$ScriptPath"
        return
    }

    try {
        $output = & $ScriptPath @Parameters *>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_ | Out-String
        $exitCode = 1
    }
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 700) {
        $detail = $detail.Substring(0, 700)
    }

    Add-Step $Name ($exitCode -ne 0) "expected-failure exit=$exitCode $detail"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}

$toolsRoot = Join-Path $PackageRoot "tools"
$validateScript = Join-Path $toolsRoot "validate-package.ps1"
$verifyScript = Join-Path $toolsRoot "verify-update-manifest.ps1"
$signingScript = Join-Path $toolsRoot "test-signing-readiness.ps1"
$localOpsScript = Join-Path $toolsRoot "local-ops.ps1"
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
$appExe = Join-Path $PackageRoot "app\SamhainSecurityNative.exe"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$archivePath = "$PackageRoot.zip"
$evidencePath = "$PackageRoot.clean-machine-evidence.json"
$steps = New-Object System.Collections.Generic.List[object]
$failed = $false
$serviceReadiness = $null
$serviceSelfCheck = $null
$protectionTransaction = $null
$engineInventory = $null

Invoke-ScriptStep -Name "validate-package" -ScriptPath $validateScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    RunServiceStatus = $true
    Json = $true
}

if ((Test-Path $updateManifestPath) -and (Test-Path $archivePath)) {
    Invoke-ScriptStep -Name "update-manifest" -ScriptPath $verifyScript -Parameters @{
        ManifestPath = $updateManifestPath
        ArchivePath = $archivePath
        ExpectedVersion = $ExpectedVersion
        RequireStableChannel = $true
        Json = $true
    }
}
else {
    Add-Step "update-manifest" $true "skipped: sibling archive or manifest not present"
}

Invoke-ScriptStep -Name "signing-readiness" -ScriptPath $signingScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "local-ops:status" -ScriptPath $localOpsScript -Parameters @{
    Action = "Status"
}
Invoke-ScriptStep -Name "local-ops:install-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Install"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:repair-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Repair"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:uninstall-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Uninstall"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:machine-status" -ScriptPath $localOpsScript -Parameters @{
    Action = "Status"
    Scope = "Machine"
}
Invoke-ScriptStep -Name "local-ops:machine-install-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Install"
    Scope = "Machine"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:machine-repair-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Repair"
    Scope = "Machine"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:machine-uninstall-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Uninstall"
    Scope = "Machine"
    DryRun = $true
}
if (-not (Test-IsAdministrator)) {
    Invoke-ExpectedFailureStep -Name "local-ops:machine-install-nonadmin-guard" -ScriptPath $localOpsScript -Parameters @{
        Action = "Install"
        Scope = "Machine"
    }
}
else {
    Add-Step "local-ops:machine-install-nonadmin-guard" $true "skipped: elevated shell"
}

if (-not (Test-Path $serviceExe)) {
    Add-Step "service:status" $false "missing=$serviceExe"
}
else {
    $serviceOutput = & $serviceExe status 2>&1
    $serviceExitCode = $LASTEXITCODE
    try {
        $serviceState = ($serviceOutput | Out-String).Trim() | ConvertFrom-Json
        $serviceReadiness = $serviceState.service_readiness
        $serviceSelfCheck = $serviceState.service_self_check
        $protectionTransaction = $serviceState.protection_policy.transaction
        $engineInventory = $serviceState.engine_catalog
        Add-Step "service:status" (($serviceExitCode -eq 0) -and ($serviceState.version -eq $ExpectedVersion)) "exit=$serviceExitCode version=$($serviceState.version) readiness=$($serviceReadiness.status)"
        Add-Step "service:self-check-state" ($null -ne $serviceSelfCheck) "status=$($serviceSelfCheck.status)"
        Add-Step "service:recovery-policy" (($null -ne $serviceState.recovery_policy) -and ($serviceState.recovery_policy.owner -eq "service")) "owner=$($serviceState.recovery_policy.owner)"
        Add-Step "service:engine-inventory" (($null -ne $engineInventory) -and ($engineInventory.Count -ge 4)) "count=$($engineInventory.Count)"
        Add-Step "service:protection-transaction" (($null -ne $protectionTransaction) -and ($protectionTransaction.steps.Count -gt 0)) "status=$($protectionTransaction.status) steps=$($protectionTransaction.steps.Count)"
    }
    catch {
        Add-Step "service:status" $false $_.Exception.Message
    }

    try {
        $selfCheckOutput = & $serviceExe self-check 2>&1
        $selfCheckExitCode = $LASTEXITCODE
        $selfCheck = ($selfCheckOutput | Out-String).Trim() | ConvertFrom-Json
        Add-Step "service:self-check-command" (($selfCheckExitCode -eq 0) -and ($null -ne $selfCheck.state)) "exit=$selfCheckExitCode status=$($selfCheck.state.status)"
        if ($null -eq $serviceSelfCheck) {
            $serviceSelfCheck = $selfCheck.state
        }
    }
    catch {
        Add-Step "service:self-check-command" $false $_.Exception.Message
    }
}

if ($SkipLaunch) {
    Add-Step "desktop:launch" $true "skipped"
}
else {
    $process = $null
    try {
        if (-not (Test-Path $appExe)) {
            Add-Step "desktop:launch" $false "missing=$appExe"
        }
        else {
            $process = Start-Process -FilePath $appExe -ArgumentList "--background" -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 4
            $alive = $false
            try {
                $alive = -not $process.HasExited
            }
            catch {
                $alive = $false
            }

            if ($alive) {
                Add-Step "desktop:launch" $true "pid=$($process.Id)"
            }
            else {
                Add-Step "desktop:launch" $false "exit=$($process.ExitCode)"
            }
        }
    }
    catch {
        Add-Step "desktop:launch" $false $_.Exception.Message
    }
    finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }
    }
}

$evidence = [PSCustomObject]@{
    ok = -not $failed
    product = "Samhain Security Native"
    version = $ExpectedVersion
    matrixCase = $MatrixCase
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    host = Get-HostFacts
    serviceReadiness = $serviceReadiness
    serviceSelfCheck = $serviceSelfCheck
    protectionTransaction = $protectionTransaction
    engineInventory = $engineInventory
    packageRoot = $PackageRoot
    steps = $steps
}

$evidence | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $evidencePath -Encoding UTF8

if ($Json) {
    $evidence | ConvertTo-Json -Depth 7
}
else {
    $steps | Format-Table -AutoSize
    Write-Host "Clean-machine evidence: $evidencePath"
}

if ($failed) {
    exit 1
}

param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
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

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}

$steps = New-Object System.Collections.Generic.List[object]
$failed = $false

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
        $global:LASTEXITCODE = 0
        $output = & $ScriptPath @Parameters *>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    }
    catch {
        $output = $_ | Out-String
        $exitCode = 1
    }
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 500) {
        $detail = $detail.Substring(0, 500)
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
        $global:LASTEXITCODE = 0
        $output = & $ScriptPath @Parameters *>&1
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    }
    catch {
        $output = $_ | Out-String
        $exitCode = 1
    }
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 500) {
        $detail = $detail.Substring(0, 500)
    }
    Add-Step $Name ($exitCode -ne 0) "expected-failure exit=$exitCode $detail"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-DesktopIntegrationStatusCheck {
    param([string]$ScriptPath)

    if (-not (Test-Path $ScriptPath)) {
        Add-Step "local-ops:desktop-integration" $false "missing=$ScriptPath"
        return
    }

    try {
        $output = & $ScriptPath -Action Status 2>&1
        $status = ($output | Out-String).Trim() | ConvertFrom-Json
        $integration = $status.desktopIntegration
        $ok = ($integration.owner -eq "local-ops") `
            -and ($integration.expected.autostartCommand -like "*SamhainSecurityNative.exe*") `
            -and ($integration.expected.urlCommand -like '*"%1"*') `
            -and ($integration.evidence -contains "single-instance-handoff=desktop") `
            -and ($integration.evidence -contains "tray-owner=desktop")
        Add-Step "local-ops:desktop-integration" $ok "status=$($integration.status) autostartOwned=$($integration.autostartOwned) urlOwned=$($integration.urlSchemeOwned)"
    }
    catch {
        Add-Step "local-ops:desktop-integration" $false $_.Exception.Message
    }
}

function Stop-PackageProcesses {
    param([string]$PackageRoot)

    foreach ($name in @("SamhainSecurityNative", "samhain-service")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-ServicePipe {
    param([int]$TimeoutMs = 1500)

    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(".", "SamhainSecurity.Native.Ipc", [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect($TimeoutMs)
        $client.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message

        $request = @{
            protocol_version = 1
            request_id = "smoke-managed-service"
            command = @{ type = "ping" }
        } | ConvertTo-Json -Compress
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $client.Write($requestBytes, 0, $requestBytes.Length)
        $client.Flush()

        $buffer = [byte[]]::new(65536)
        $read = $client.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            $client.Dispose()
            return $false
        }

        $responseText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $response = $responseText | ConvertFrom-Json
        $client.Dispose()
        return (($response.ok -eq $true) -and ($response.event.type -eq "pong"))
    }
    catch {
        return $false
    }
}

function Wait-PackageServiceReady {
    param(
        [string]$PackageRoot,
        [int]$TimeoutMs = 10000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $serviceProcess = $null
    $pipeReady = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        $serviceProcess = Get-Process -Name "samhain-service" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Path -and [System.IO.Path]::GetFullPath($_.Path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Select-Object -First 1

        if ($null -ne $serviceProcess) {
            $pipeReady = Test-ServicePipe -TimeoutMs 1000
            if ($pipeReady) {
                break
            }
        }

        Start-Sleep -Milliseconds 250
    }

    [pscustomobject]@{
        Process = $serviceProcess
        PipeReady = $pipeReady
    }
}

$toolsRoot = Join-Path $PackageRoot "tools"
$validateScript = Join-Path $toolsRoot "validate-package.ps1"
$updateVerifierScript = Join-Path $toolsRoot "verify-update-manifest.ps1"
$proxyPathSmokeScript = Join-Path $toolsRoot "smoke-proxy-path.ps1"
$tunPathSmokeScript = Join-Path $toolsRoot "smoke-tun-path.ps1"
$adapterPathSmokeScript = Join-Path $toolsRoot "smoke-adapter-path.ps1"
$signingScript = Join-Path $toolsRoot "test-signing-readiness.ps1"
$privilegedServiceReadinessScript = Join-Path $toolsRoot "test-privileged-service-readiness.ps1"
$cleanMachineScript = Join-Path $toolsRoot "write-clean-machine-evidence.ps1"
$releaseNotesScript = Join-Path $toolsRoot "write-release-notes.ps1"
$runtimeBundleScript = Join-Path $toolsRoot "prepare-runtime-bundle.ps1"
$localOpsScript = Join-Path $toolsRoot "local-ops.ps1"
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
$appExe = Join-Path $PackageRoot "app\SamhainSecurityNative.exe"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$archivePath = "$PackageRoot.zip"

Invoke-ScriptStep -Name "validate-package" -ScriptPath $validateScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    RunServiceStatus = $true
    Json = $true
}
Invoke-ScriptStep -Name "runtime-bundle" -ScriptPath $runtimeBundleScript -Parameters @{
    PackageRoot = $PackageRoot
    ValidateOnly = $true
    Json = $true
}
Invoke-ScriptStep -Name "proxy-path-smoke" -ScriptPath $proxyPathSmokeScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "tun-path-smoke" -ScriptPath $tunPathSmokeScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "adapter-path-smoke" -ScriptPath $adapterPathSmokeScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "update-manifest" -ScriptPath $updateVerifierScript -Parameters @{
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ExpectedFailureStep -Name "update-manifest:downgrade-guard" -ScriptPath $updateVerifierScript -Parameters @{
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    InstalledVersion = "9.9.9"
    Json = $true
}
Invoke-ScriptStep -Name "update-manifest:recovery-override" -ScriptPath $updateVerifierScript -Parameters @{
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    InstalledVersion = "9.9.9"
    AllowDowngradeRecovery = $true
    Json = $true
}
Invoke-ScriptStep -Name "signing-readiness" -ScriptPath $signingScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "privileged-service-readiness" -ScriptPath $privilegedServiceReadinessScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "clean-machine-evidence" -ScriptPath $cleanMachineScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    MatrixCase = "package-smoke-local"
    SkipLaunch = $true
    Json = $true
}
Invoke-ScriptStep -Name "release-notes" -ScriptPath $releaseNotesScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "local-ops:status" -ScriptPath $localOpsScript -Parameters @{
    Action = "Status"
}
Invoke-DesktopIntegrationStatusCheck -ScriptPath $localOpsScript
Invoke-ScriptStep -Name "local-ops:install-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Install"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:repair-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Repair"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:rollback-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Rollback"
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
Invoke-ScriptStep -Name "local-ops:machine-rollback-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Rollback"
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
        Add-Step "service:status" (($serviceExitCode -eq 0) -and ($serviceState.version -eq $ExpectedVersion)) "exit=$serviceExitCode version=$($serviceState.version)"
        Add-Step "service:self-check-state" ($null -ne $serviceState.service_self_check) "status=$($serviceState.service_self_check.status)"
        Add-Step "service:recovery-policy" (($null -ne $serviceState.recovery_policy) -and ($serviceState.recovery_policy.owner -eq "service")) "owner=$($serviceState.recovery_policy.owner)"
        Add-Step "service:engine-inventory" (($null -ne $serviceState.engine_catalog) -and ($serviceState.engine_catalog.Count -ge 4)) "count=$($serviceState.engine_catalog.Count)"
        Add-Step "service:runtime-health" ($null -ne $serviceState.runtime_health) "status=$($serviceState.runtime_health.status) source=$($serviceState.runtime_health.metrics_source)"
        Add-Step "service:subscription-operations" ($null -ne $serviceState.subscription_operations) "status=$($serviceState.subscription_operations.status)"
        Add-Step "service:protection-transaction" (($null -ne $serviceState.protection_policy.transaction) -and ($serviceState.protection_policy.transaction.steps.Count -gt 0)) "status=$($serviceState.protection_policy.transaction.status) steps=$($serviceState.protection_policy.transaction.steps.Count)"
    }
    catch {
        Add-Step "service:status" $false $_.Exception.Message
    }

    try {
        $selfCheckOutput = & $serviceExe self-check 2>&1
        $selfCheckExitCode = $LASTEXITCODE
        $selfCheck = ($selfCheckOutput | Out-String).Trim() | ConvertFrom-Json
        Add-Step "service:self-check-command" (($selfCheckExitCode -eq 0) -and ($null -ne $selfCheck.state)) "exit=$selfCheckExitCode status=$($selfCheck.state.status)"
    }
    catch {
        Add-Step "service:self-check-command" $false $_.Exception.Message
    }
}

if (-not $SkipLaunch) {
    $process = $null
    try {
        Stop-PackageProcesses -PackageRoot $PackageRoot
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
                $serviceReady = Wait-PackageServiceReady -PackageRoot $PackageRoot -TimeoutMs 10000
                $serviceProcess = $serviceReady.Process
                $pipeReady = $serviceReady.PipeReady
                Add-Step "desktop:managed-service" (($null -ne $serviceProcess) -and $pipeReady) "pid=$($serviceProcess.Id) pipe=$pipeReady"
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

        Get-Process -Name SamhainSecurityNative -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
        Stop-PackageProcesses -PackageRoot $PackageRoot
    }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $steps | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Package smoke failed: $PackageRoot"
    }
    else {
        Write-Host "Package smoke passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

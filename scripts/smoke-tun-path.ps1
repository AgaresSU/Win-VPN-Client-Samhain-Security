param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$SubscriptionUrl = "",
    [string]$SubscriptionName = "Samhain Security TUN Smoke",
    [int]$TimeoutSeconds = 20,
    [switch]$AllowLiveTun,
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

function Stop-ScopedProcesses {
    param([string]$PackageRoot)

    foreach ($name in @("SamhainSecurityNative", "samhain-service", "sing-box", "xray")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-IpcCommand {
    param(
        [hashtable]$Command,
        [string]$RequestId,
        [int]$TimeoutMs = 4000
    )

    $client = [System.IO.Pipes.NamedPipeClientStream]::new(".", "SamhainSecurity.Native.Ipc", [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect($TimeoutMs)
        $client.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
        $request = @{
            protocol_version = 1
            request_id = $RequestId
            command = $Command
        } | ConvertTo-Json -Depth 16 -Compress
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($request)
        $client.Write($requestBytes, 0, $requestBytes.Length)
        $client.Flush()

        $buffer = [byte[]]::new(262144)
        $read = $client.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            throw "empty IPC response"
        }

        $responseText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        return ($responseText | ConvertFrom-Json)
    }
    finally {
        $client.Dispose()
    }
}

function Wait-ServiceReady {
    param([int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-IpcCommand -Command @{ type = "ping" } -RequestId "tun-smoke-ping" -TimeoutMs 1000
            if ($response.ok -eq $true -and $response.event.type -eq "pong") {
                return $true
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 250
    }

    return $false
}

function Get-PackageRuntimeProcesses {
    param([string]$PackageRoot)

    @(Get-Process -Name "sing-box", "xray" -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [System.IO.Path]::GetFullPath($_.Path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($SubscriptionUrl) -and -not [string]::IsNullOrWhiteSpace($env:SAMHAIN_SMOKE_SUBSCRIPTION_URL)) {
    $SubscriptionUrl = $env:SAMHAIN_SMOKE_SUBSCRIPTION_URL
}
$subscriptionSource = "operator-supplied"
if ([string]::IsNullOrWhiteSpace($SubscriptionUrl)) {
    $SubscriptionUrl = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=tcp&security=reality&pbk=public-smoke-key&sid=short&sni=example.com&fp=chrome#Samhain%20Smoke%20TUN"
    $subscriptionSource = "synthetic-profile"
}

$steps = New-Object System.Collections.Generic.List[object]
$failed = $false
$serviceProcess = $null
$storagePath = Join-Path $env:TEMP ("samhain-tun-smoke-" + [guid]::NewGuid().ToString() + ".json")
$previousStorage = $env:SAMHAIN_STORAGE_PATH
$previousProxyDryRun = $env:SAMHAIN_PROXY_DRY_RUN
$previousProtectionDryRun = $env:SAMHAIN_PROTECTION_DRY_RUN
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"

try {
    Add-Step "package:version" ((Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim() -eq $ExpectedVersion) "expected=$ExpectedVersion"
    Add-Step "service:exe" (Test-Path $serviceExe) $serviceExe
    if (-not (Test-Path $serviceExe)) {
        throw "service executable is missing"
    }

    Stop-ScopedProcesses -PackageRoot $PackageRoot
    $env:SAMHAIN_STORAGE_PATH = $storagePath
    $env:SAMHAIN_PROXY_DRY_RUN = "1"
    $env:SAMHAIN_PROTECTION_DRY_RUN = "1"
    $serviceProcess = Start-Process -FilePath $serviceExe -ArgumentList "run" -WindowStyle Hidden -PassThru
    Add-Step "service:start" ($null -ne $serviceProcess) "pid=$($serviceProcess.Id)"
    Add-Step "service:pipe" (Wait-ServiceReady -TimeoutSeconds $TimeoutSeconds) "ready"

    $initialStateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "tun-smoke-initial"
    $readiness = $initialStateResponse.event.service_readiness
    $privilegedAllowed = [bool]$readiness.privileged_policy_allowed
    Add-Step "elevation:readiness" ($initialStateResponse.ok -eq $true) "status=$($readiness.status) allowed=$privilegedAllowed"

    $addResponse = Invoke-IpcCommand -Command @{
        type = "add-subscription"
        name = $SubscriptionName
        url = $SubscriptionUrl
    } -RequestId "tun-smoke-add" -TimeoutMs ($TimeoutSeconds * 1000)
    $servers = @($addResponse.event.subscription.servers)
    $tunServer = $servers |
        Where-Object { [string]$_.protocol -notin @("wire-guard", "amnezia-wg") } |
        Select-Object -First 1
    Add-Step "subscription:import" ($addResponse.ok -eq $true -and $servers.Count -gt 0) "source=$subscriptionSource servers=$($servers.Count)"
    Add-Step "subscription:tun-server" ($null -ne $tunServer) "protocol=$($tunServer.protocol)"
    if ($null -eq $tunServer) {
        throw "no TUN-capable proxy server was imported"
    }

    $previewResponse = Invoke-IpcCommand -Command @{
        type = "preview-engine-config"
        server_id = [string]$tunServer.id
    } -RequestId "tun-smoke-preview"
    $previewText = [string]$previewResponse.event.preview.redacted_config
    $warnings = @($previewResponse.event.preview.warnings)
    $warningText = $warnings -join "`n"
    Add-Step "engine:preview" ($previewResponse.ok -eq $true -and $previewText.Contains('"type": "tun"') -and $previewText.Contains('"auto_route": true')) "engine=$($previewResponse.event.preview.engine) warnings=$($warnings.Count)"
    Add-Step "elevation:warning" ($warningText.Contains("TUN")) "warnings=$($warnings.Count)"

    if ($privilegedAllowed -and -not $AllowLiveTun) {
        Add-Step "tun:live-skip" $true "privileged environment detected; pass -AllowLiveTun for live route creation"
    }
    else {
        $startResponse = Invoke-IpcCommand -Command @{
            type = "start-engine"
            server_id = [string]$tunServer.id
            route_mode = "whole-computer"
        } -RequestId "tun-smoke-start" -TimeoutMs ($TimeoutSeconds * 1000)

        if ($privilegedAllowed -and $AllowLiveTun) {
            Add-Step "engine:start-live" ($startResponse.ok -eq $true -and $startResponse.event.state.status -eq "running") "status=$($startResponse.event.state.status) pid=$($startResponse.event.state.pid)"
            $stateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "tun-smoke-live-state"
            $runtimeHealth = $stateResponse.event.runtime_health
            Add-Step "runtime:health" ($stateResponse.ok -eq $true -and $runtimeHealth.route_path -eq "TUN path" -and $runtimeHealth.status -in @("fallback-telemetry", "runtime-metrics")) "status=$($runtimeHealth.status) path=$($runtimeHealth.route_path)"
            $stopResponse = Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "tun-smoke-live-stop"
            Add-Step "engine:stop-live" ($stopResponse.ok -eq $true -and $stopResponse.event.state.status -eq "stopped") "status=$($stopResponse.event.state.status)"
        }
        else {
            $errorMessage = [string]$startResponse.event.message
            Add-Step "tun:elevation-gate" ($startResponse.ok -eq $true -and $startResponse.event.type -eq "error" -and $errorMessage.Contains("TUN path is gated")) "event=$($startResponse.event.type) message=$errorMessage"

            $engineStatus = Invoke-IpcCommand -Command @{ type = "get-engine-status" } -RequestId "tun-smoke-engine"
            Add-Step "engine:blocked" ($engineStatus.ok -eq $true -and $engineStatus.event.state.status -eq "blocked") "status=$($engineStatus.event.state.status)"

            $stateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "tun-smoke-state"
            $runtimeHealth = $stateResponse.event.runtime_health
            Add-Step "runtime:gated" ($stateResponse.ok -eq $true -and $runtimeHealth.status -eq "gated") "status=$($runtimeHealth.status) path=$($runtimeHealth.route_path)"

            $tunStatus = Invoke-IpcCommand -Command @{ type = "get-tun-status" } -RequestId "tun-smoke-tun-status"
            Add-Step "tun:not-active" ($tunStatus.ok -eq $true -and $tunStatus.event.state.enabled -eq $false -and $tunStatus.event.state.status -in @("inactive", "restored")) "status=$($tunStatus.event.state.status) enabled=$($tunStatus.event.state.enabled)"
        }
    }

    $restoreResponse = Invoke-IpcCommand -Command @{ type = "restore-tun-policy" } -RequestId "tun-smoke-restore"
    Add-Step "tun:restore" ($restoreResponse.ok -eq $true -and $restoreResponse.event.state.enabled -eq $false -and $restoreResponse.event.state.status -eq "restored") "status=$($restoreResponse.event.state.status)"

    $emergencyResponse = Invoke-IpcCommand -Command @{ type = "emergency-restore" } -RequestId "tun-smoke-emergency"
    Add-Step "recovery:emergency" ($emergencyResponse.ok -eq $true -and $emergencyResponse.event.tun_state.enabled -eq $false -and $null -eq $emergencyResponse.event.connected_server_id) "engine=$($emergencyResponse.event.engine_state.status) tun=$($emergencyResponse.event.tun_state.status)"

    Start-Sleep -Milliseconds 500
    $remaining = Get-PackageRuntimeProcesses -PackageRoot $PackageRoot
    Add-Step "engine:cleanup" ($remaining.Count -eq 0) "remaining=$($remaining.Count)"
}
catch {
    Add-Step "tun-smoke:error" $false $_.Exception.Message
}
finally {
    try {
        Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "tun-smoke-final-stop" -TimeoutMs 1500 | Out-Null
    }
    catch {
    }
    if ($serviceProcess) {
        try {
            if (-not $serviceProcess.HasExited) {
                Stop-Process -Id $serviceProcess.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
    Stop-ScopedProcesses -PackageRoot $PackageRoot
    Remove-Item -LiteralPath $storagePath -Force -ErrorAction SilentlyContinue

    if ($null -eq $previousStorage) { Remove-Item Env:\SAMHAIN_STORAGE_PATH -ErrorAction SilentlyContinue } else { $env:SAMHAIN_STORAGE_PATH = $previousStorage }
    if ($null -eq $previousProxyDryRun) { Remove-Item Env:\SAMHAIN_PROXY_DRY_RUN -ErrorAction SilentlyContinue } else { $env:SAMHAIN_PROXY_DRY_RUN = $previousProxyDryRun }
    if ($null -eq $previousProtectionDryRun) { Remove-Item Env:\SAMHAIN_PROTECTION_DRY_RUN -ErrorAction SilentlyContinue } else { $env:SAMHAIN_PROTECTION_DRY_RUN = $previousProtectionDryRun }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    liveTunAllowed = [bool]$AllowLiveTun
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $steps | Format-Table -AutoSize
    if ($failed) {
        Write-Host "TUN path smoke failed: $PackageRoot"
    }
    else {
        Write-Host "TUN path smoke passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

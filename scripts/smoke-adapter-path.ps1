param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$SubscriptionUrl = "",
    [string]$SubscriptionName = "Samhain Security Adapter Smoke",
    [int]$TimeoutSeconds = 20,
    [switch]$AllowLiveAdapter,
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

    foreach ($name in @("SamhainSecurityNative", "samhain-service", "sing-box", "xray", "wireguard", "amneziawg", "wg", "awg")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-PackageRuntimeProcesses {
    param([string]$PackageRoot)

    @(Get-Process -Name "sing-box", "xray", "wireguard", "amneziawg", "wg", "awg" -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [System.IO.Path]::GetFullPath($_.Path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
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
            $response = Invoke-IpcCommand -Command @{ type = "ping" } -RequestId "adapter-smoke-ping" -TimeoutMs 1000
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

function Stop-SmokeService {
    if ($script:serviceProcess) {
        try {
            if (-not $script:serviceProcess.HasExited) {
                Stop-Process -Id $script:serviceProcess.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
        $script:serviceProcess = $null
    }
    Stop-ScopedProcesses -PackageRoot $script:PackageRoot
    Start-Sleep -Milliseconds 300
}

function Start-SmokeService {
    param(
        [string]$Phase,
        [bool]$AdapterDryRun
    )

    Stop-SmokeService
    if ($AdapterDryRun) {
        $env:SAMHAIN_ADAPTER_DRY_RUN = "1"
    }
    else {
        Remove-Item Env:\SAMHAIN_ADAPTER_DRY_RUN -ErrorAction SilentlyContinue
    }

    $script:serviceProcess = Start-Process -FilePath $script:serviceExe -ArgumentList "run" -WindowStyle Hidden -PassThru
    Add-Step "service:start-$Phase" ($null -ne $script:serviceProcess) "pid=$($script:serviceProcess.Id) adapterDryRun=$AdapterDryRun"
    $ready = Wait-ServiceReady -TimeoutSeconds $TimeoutSeconds
    Add-Step "service:pipe-$Phase" $ready "ready"
    if (-not $ready) {
        throw "service pipe was not ready during $Phase"
    }
}

function Invoke-AdapterLifecycle {
    param(
        [string]$Label,
        [object]$Server,
        [string]$ExpectedEngine,
        [string]$ExpectedRuntime
    )

    $startResponse = Invoke-IpcCommand -Command @{
        type = "start-engine"
        server_id = [string]$Server.id
        route_mode = "whole-computer"
    } -RequestId "adapter-smoke-start-$Label" -TimeoutMs ($TimeoutSeconds * 1000)
    $state = $startResponse.event.state
    Add-Step "adapter:${Label}:start" ($startResponse.ok -eq $true -and $state.status -eq "running" -and [string]$state.engine -eq $ExpectedEngine) "status=$($state.status) engine=$($state.engine) pid=$($state.pid)"

    $configPath = [string]$state.config_path
    Add-Step "adapter:${Label}:config-file" (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path -LiteralPath $configPath)) $configPath

    $stateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "adapter-smoke-state-$Label"
    $runtimeHealth = $stateResponse.event.runtime_health
    Add-Step "adapter:${Label}:runtime-health" ($stateResponse.ok -eq $true -and $runtimeHealth.route_path -eq "adapter path" -and $runtimeHealth.status -in @("fallback-telemetry", "runtime-metrics") -and [string]$runtimeHealth.engine -eq $ExpectedEngine) "status=$($runtimeHealth.status) path=$($runtimeHealth.route_path)"

    $inventory = @($stateResponse.event.engine_catalog | Where-Object { [string]$_.runtime_id -eq $ExpectedRuntime })
    Add-Step "adapter:${Label}:runtime-inventory" ($inventory.Count -eq 1 -and $inventory[0].available -eq $true) "runtime=$ExpectedRuntime status=$($inventory[0].status)"

    $stopResponse = Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "adapter-smoke-stop-$Label" -TimeoutMs ($TimeoutSeconds * 1000)
    Add-Step "adapter:${Label}:stop" ($stopResponse.ok -eq $true -and $stopResponse.event.state.status -eq "stopped") "status=$($stopResponse.event.state.status)"
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($SubscriptionUrl) -and -not [string]::IsNullOrWhiteSpace($env:SAMHAIN_SMOKE_ADAPTER_SUBSCRIPTION_URL)) {
    $SubscriptionUrl = $env:SAMHAIN_SMOKE_ADAPTER_SUBSCRIPTION_URL
}
$subscriptionSource = "operator-supplied"
if ([string]::IsNullOrWhiteSpace($SubscriptionUrl)) {
    $SubscriptionUrl = @'
{"items":[{"title":"Samhain US WireGuard #1","protocol":"wireguard","config_text":"[Interface]\nPrivateKey = wg-private-smoke\nAddress = 10.44.0.2/32\nDNS = 1.1.1.1\nMTU = 1420\n\n[Peer]\nPublicKey = wg-public-smoke\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 203.0.113.20:51820\nPersistentKeepalive = 25\n"},{"title":"Samhain DE Frankfurt AWG #2","protocol":"amneziawg","config_text":"[Interface]\nPrivateKey = awg-private-smoke\nAddress = 10.45.0.2/32\nDNS = 1.1.1.1\nMTU = 1420\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 10\nS2 = 20\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n\n[Peer]\nPublicKey = awg-public-smoke\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = 198.51.100.20:51820\nPersistentKeepalive = 25\n"}]}
'@
    $subscriptionSource = "synthetic-profile"
}

$steps = New-Object System.Collections.Generic.List[object]
$failed = $false
$serviceProcess = $null
$storagePath = Join-Path $env:TEMP ("samhain-adapter-smoke-" + [guid]::NewGuid().ToString() + ".json")
$previousStorage = $env:SAMHAIN_STORAGE_PATH
$previousProxyDryRun = $env:SAMHAIN_PROXY_DRY_RUN
$previousProtectionDryRun = $env:SAMHAIN_PROTECTION_DRY_RUN
$previousAdapterDryRun = $env:SAMHAIN_ADAPTER_DRY_RUN
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
$script:PackageRoot = $PackageRoot
$script:serviceExe = $serviceExe

try {
    Add-Step "package:version" ((Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim() -eq $ExpectedVersion) "expected=$ExpectedVersion"
    Add-Step "service:exe" (Test-Path $serviceExe) $serviceExe
    if (-not (Test-Path $serviceExe)) {
        throw "service executable is missing"
    }

    $env:SAMHAIN_STORAGE_PATH = $storagePath
    $env:SAMHAIN_PROXY_DRY_RUN = "1"
    $env:SAMHAIN_PROTECTION_DRY_RUN = "1"

    Start-SmokeService -Phase "gate" -AdapterDryRun $false
    $initialStateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "adapter-smoke-initial"
    $readiness = $initialStateResponse.event.service_readiness
    $privilegedAllowed = [bool]$readiness.privileged_policy_allowed
    Add-Step "elevation:readiness" ($initialStateResponse.ok -eq $true) "status=$($readiness.status) allowed=$privilegedAllowed"

    $addResponse = Invoke-IpcCommand -Command @{
        type = "add-subscription"
        name = $SubscriptionName
        url = $SubscriptionUrl
    } -RequestId "adapter-smoke-add" -TimeoutMs ($TimeoutSeconds * 1000)
    $servers = @($addResponse.event.subscription.servers)
    $wireGuardServer = $servers | Where-Object { [string]$_.protocol -eq "wire-guard" } | Select-Object -First 1
    $amneziaServer = $servers | Where-Object { [string]$_.protocol -eq "amnezia-wg" } | Select-Object -First 1
    Add-Step "subscription:import" ($addResponse.ok -eq $true -and $servers.Count -ge 2) "source=$subscriptionSource servers=$($servers.Count)"
    Add-Step "subscription:wireguard" ($null -ne $wireGuardServer) "id=$($wireGuardServer.id)"
    Add-Step "subscription:amneziawg" ($null -ne $amneziaServer) "id=$($amneziaServer.id)"
    if ($null -eq $wireGuardServer -or $null -eq $amneziaServer) {
        throw "adapter subscription did not import both WireGuard and AmneziaWG"
    }

    $previewCases = @(
        @{ label = "wireguard"; server = $wireGuardServer; engine = "wire-guard"; secret = "wg-private-smoke" },
        @{ label = "amneziawg"; server = $amneziaServer; engine = "amnezia-wg"; secret = "awg-private-smoke" }
    )
    foreach ($case in $previewCases) {
        $label = [string]$case["label"]
        $server = $case["server"]
        $previewResponse = Invoke-IpcCommand -Command @{
            type = "preview-engine-config"
            server_id = [string]$server.id
        } -RequestId "adapter-smoke-preview-$label"
        $previewText = [string]$previewResponse.event.preview.redacted_config
        $warnings = @($previewResponse.event.preview.warnings)
        $warningText = $warnings -join "`n"
        Add-Step "preview:${label}:config" ($previewResponse.ok -eq $true -and [string]$previewResponse.event.preview.engine -eq [string]$case["engine"] -and $previewText.Contains("[Interface]") -and $previewText.Contains("[Peer]")) "engine=$($previewResponse.event.preview.engine) warnings=$($warnings.Count)"
        Add-Step "preview:${label}:redaction" (-not $previewText.Contains([string]$case["secret"]) -and $previewText.Contains("<redacted>")) "redacted"
        Add-Step "preview:${label}:adapter-warning" ($warningText.Contains("Адаптерный путь") -or $warningText.Contains("Adapter path")) "warnings=$($warnings.Count)"
    }

    if ($privilegedAllowed) {
        Add-Step "adapter:elevation-gate" $true "privileged environment detected; gate is not expected"
    }
    else {
        $startResponse = Invoke-IpcCommand -Command @{
            type = "start-engine"
            server_id = [string]$wireGuardServer.id
            route_mode = "whole-computer"
        } -RequestId "adapter-smoke-gate" -TimeoutMs ($TimeoutSeconds * 1000)
        $errorMessage = [string]$startResponse.event.message
        Add-Step "adapter:elevation-gate" ($startResponse.ok -eq $true -and $startResponse.event.type -eq "error" -and $errorMessage.Contains("Adapter path is gated")) "event=$($startResponse.event.type) message=$errorMessage"

        $engineStatus = Invoke-IpcCommand -Command @{ type = "get-engine-status" } -RequestId "adapter-smoke-blocked"
        Add-Step "adapter:blocked" ($engineStatus.ok -eq $true -and $engineStatus.event.state.status -eq "blocked") "status=$($engineStatus.event.state.status)"

        $stateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "adapter-smoke-gated-state"
        $runtimeHealth = $stateResponse.event.runtime_health
        Add-Step "runtime:gated" ($stateResponse.ok -eq $true -and $runtimeHealth.status -eq "gated") "status=$($runtimeHealth.status) path=$($runtimeHealth.route_path)"
    }

    Stop-SmokeService
    $useAdapterDryRun = -not ($privilegedAllowed -and $AllowLiveAdapter)
    $adapterMode = if ($useAdapterDryRun) { "dry-run" } else { "live" }
    Start-SmokeService -Phase "adapter" -AdapterDryRun $useAdapterDryRun
    Add-Step "adapter:mode" $true $adapterMode

    Invoke-AdapterLifecycle -Label "wireguard" -Server $wireGuardServer -ExpectedEngine "wire-guard" -ExpectedRuntime "wireguard"
    Invoke-AdapterLifecycle -Label "amneziawg" -Server $amneziaServer -ExpectedEngine "amnezia-wg" -ExpectedRuntime "amneziawg"

    $emergencyResponse = Invoke-IpcCommand -Command @{ type = "emergency-restore" } -RequestId "adapter-smoke-emergency"
    Add-Step "recovery:emergency" ($emergencyResponse.ok -eq $true -and $emergencyResponse.event.tun_state.enabled -eq $false -and $null -eq $emergencyResponse.event.connected_server_id) "engine=$($emergencyResponse.event.engine_state.status) tun=$($emergencyResponse.event.tun_state.status)"

    Start-Sleep -Milliseconds 500
    $remaining = Get-PackageRuntimeProcesses -PackageRoot $PackageRoot
    Add-Step "adapter:cleanup" ($remaining.Count -eq 0) "remaining=$($remaining.Count)"
}
catch {
    Add-Step "adapter-smoke:error" $false $_.Exception.Message
}
finally {
    try {
        Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "adapter-smoke-final-stop" -TimeoutMs 1500 | Out-Null
    }
    catch {
    }
    Stop-SmokeService
    Remove-Item -LiteralPath $storagePath -Force -ErrorAction SilentlyContinue

    if ($null -eq $previousStorage) { Remove-Item Env:\SAMHAIN_STORAGE_PATH -ErrorAction SilentlyContinue } else { $env:SAMHAIN_STORAGE_PATH = $previousStorage }
    if ($null -eq $previousProxyDryRun) { Remove-Item Env:\SAMHAIN_PROXY_DRY_RUN -ErrorAction SilentlyContinue } else { $env:SAMHAIN_PROXY_DRY_RUN = $previousProxyDryRun }
    if ($null -eq $previousProtectionDryRun) { Remove-Item Env:\SAMHAIN_PROTECTION_DRY_RUN -ErrorAction SilentlyContinue } else { $env:SAMHAIN_PROTECTION_DRY_RUN = $previousProtectionDryRun }
    if ($null -eq $previousAdapterDryRun) { Remove-Item Env:\SAMHAIN_ADAPTER_DRY_RUN -ErrorAction SilentlyContinue } else { $env:SAMHAIN_ADAPTER_DRY_RUN = $previousAdapterDryRun }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    liveAdapterAllowed = [bool]$AllowLiveAdapter
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $steps | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Adapter path smoke failed: $PackageRoot"
    }
    else {
        Write-Host "Adapter path smoke passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

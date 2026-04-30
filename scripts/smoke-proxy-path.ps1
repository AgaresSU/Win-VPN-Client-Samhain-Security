param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$SubscriptionUrl = "",
    [string]$SubscriptionName = "Samhain Security Proxy Smoke",
    [int]$TimeoutSeconds = 20,
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
            $response = Invoke-IpcCommand -Command @{ type = "ping" } -RequestId "proxy-smoke-ping" -TimeoutMs 1000
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

function Test-TcpPort {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 600
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return $false
        }
        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Wait-ProxyEndpoint {
    param([int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-TcpPort -HostName "127.0.0.1" -Port 20808) {
            return $true
        }

        try {
            $status = Invoke-IpcCommand -Command @{ type = "get-engine-status" } -RequestId "proxy-smoke-engine" -TimeoutMs 1500
            if ($status.event.state.status -in @("failed", "crashed", "missing")) {
                return $false
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 300
    }

    return $false
}

function Redacted-Source {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "synthetic-profile"
    }
    return "operator-supplied"
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
    $SubscriptionUrl = "trojan://smoke-secret@127.0.0.1:443?sni=example.com#Samhain%20Smoke%20Proxy"
    $subscriptionSource = "synthetic-profile"
}

$steps = New-Object System.Collections.Generic.List[object]
$failed = $false
$serviceProcess = $null
$storagePath = Join-Path $env:TEMP ("samhain-proxy-smoke-" + [guid]::NewGuid().ToString() + ".json")
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

    $routeResponse = Invoke-IpcCommand -Command @{
        type = "set-app-routing-policy"
        route_mode = "selected-apps-only"
        applications = @(
            @{
                id = "proxy-smoke-service"
                name = "samhain-service.exe"
                path = $serviceExe
                enabled = $true
            }
        )
    } -RequestId "proxy-smoke-route"
    Add-Step "routing:proxy-aware" ($routeResponse.ok -eq $true -and $routeResponse.event.state.supported -eq $true) "status=$($routeResponse.event.state.status)"

    $addResponse = Invoke-IpcCommand -Command @{
        type = "add-subscription"
        name = $SubscriptionName
        url = $SubscriptionUrl
    } -RequestId "proxy-smoke-add" -TimeoutMs ($TimeoutSeconds * 1000)
    $servers = @($addResponse.event.subscription.servers)
    $proxyServer = $servers |
        Where-Object { [string]$_.protocol -notin @("wire-guard", "amnezia-wg") } |
        Select-Object -First 1
    Add-Step "subscription:import" ($addResponse.ok -eq $true -and $servers.Count -gt 0) "source=$subscriptionSource servers=$($servers.Count)"
    Add-Step "subscription:proxy-server" ($null -ne $proxyServer) "protocol=$($proxyServer.protocol)"
    if ($null -eq $proxyServer) {
        throw "no proxy-path server was imported"
    }

    $previewResponse = Invoke-IpcCommand -Command @{
        type = "preview-engine-config"
        server_id = [string]$proxyServer.id
    } -RequestId "proxy-smoke-preview"
    Add-Step "engine:preview" ($previewResponse.ok -eq $true) "engine=$($previewResponse.event.preview.engine)"

    $startResponse = Invoke-IpcCommand -Command @{
        type = "start-engine"
        server_id = [string]$proxyServer.id
        route_mode = "selected-apps-only"
    } -RequestId "proxy-smoke-start" -TimeoutMs ($TimeoutSeconds * 1000)
    Add-Step "engine:start" ($startResponse.ok -eq $true -and $startResponse.event.state.status -eq "running") "status=$($startResponse.event.state.status) pid=$($startResponse.event.state.pid)"

    $proxyReady = Wait-ProxyEndpoint -TimeoutSeconds $TimeoutSeconds
    Add-Step "proxy:endpoint" $proxyReady "127.0.0.1:20808"

    $stateResponse = Invoke-IpcCommand -Command @{ type = "get-state" } -RequestId "proxy-smoke-state"
    $runtimeHealth = $stateResponse.event.runtime_health
    Add-Step "runtime:health" ($stateResponse.ok -eq $true -and $runtimeHealth.route_path -eq "proxy path" -and $runtimeHealth.status -in @("fallback-telemetry", "runtime-metrics")) "status=$($runtimeHealth.status) path=$($runtimeHealth.route_path)"

    $stopResponse = Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "proxy-smoke-stop"
    Add-Step "engine:stop" ($stopResponse.ok -eq $true -and $stopResponse.event.state.status -eq "stopped") "status=$($stopResponse.event.state.status)"
    Start-Sleep -Milliseconds 500

    $remaining = @(Get-Process -Name "sing-box", "xray" -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [System.IO.Path]::GetFullPath($_.Path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)
    })
    Add-Step "engine:cleanup" ($remaining.Count -eq 0) "remaining=$($remaining.Count)"
}
catch {
    Add-Step "proxy-smoke:error" $false $_.Exception.Message
}
finally {
    try {
        Invoke-IpcCommand -Command @{ type = "stop-engine" } -RequestId "proxy-smoke-final-stop" -TimeoutMs 1500 | Out-Null
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
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $steps | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Proxy path smoke failed: $PackageRoot"
    }
    else {
        Write-Host "Proxy path smoke passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

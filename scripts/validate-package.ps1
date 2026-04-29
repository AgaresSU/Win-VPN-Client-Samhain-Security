param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [switch]$RunServiceStatus,
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
$checks = New-Object System.Collections.Generic.List[object]
$failed = $false

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

$requiredPaths = @(
    "app\SamhainSecurityNative.exe",
    "service\samhain-service.exe",
    "tools\local-ops.ps1",
    "tools\validate-package.ps1",
    "tools\smoke-package.ps1",
    "tools\verify-update-manifest.ps1",
    "tools\write-release-evidence.ps1",
    "tools\test-signing-readiness.ps1",
    "tools\write-clean-machine-evidence.ps1",
    "assets",
    "docs",
    "README.md",
    "VERSION",
    "release-manifest.json",
    "engine-inventory.json",
    "checksums.txt"
)

foreach ($relative in $requiredPaths) {
    $path = Join-Path $PackageRoot $relative
    Add-Check "required:$relative" (Test-Path $path) $path
}

$versionFile = Join-Path $PackageRoot "VERSION"
$packageVersion = ""
if (Test-Path $versionFile) {
    $packageVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    Add-Check "version:file" (-not [string]::IsNullOrWhiteSpace($packageVersion)) $packageVersion
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    Add-Check "version:expected" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
}

$manifestPath = Join-Path $PackageRoot "release-manifest.json"
$manifest = $null
if (Test-Path $manifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Add-Check "manifest:json" $true "parsed"
        Add-Check "manifest:product" ($manifest.product -eq "Samhain Security Native") ([string]$manifest.product)
        Add-Check "manifest:version" ($manifest.version -eq $packageVersion) "manifest=$($manifest.version) file=$packageVersion"
        Add-Check "manifest:operations" ($manifest.operations.script -eq "tools\local-ops.ps1") ([string]$manifest.operations.script)
        Add-Check "manifest:operations-scope" ($manifest.operations.scope -eq "CurrentUser") ([string]$manifest.operations.scope)
        Add-Check "manifest:privileged-service" ($manifest.operations.privilegedService.status -eq "installer-owned") ([string]$manifest.operations.privilegedService.status)
        Add-Check "manifest:privileged-service-name" ($manifest.operations.privilegedService.serviceName -eq "SamhainSecurityService") ([string]$manifest.operations.privilegedService.serviceName)
        Add-Check "manifest:privileged-service-elevation" ([bool]$manifest.operations.privilegedService.requiresElevation) ([string]$manifest.operations.privilegedService.requiresElevation)
        Add-Check "manifest:privileged-service-dry-run" (-not [bool]$manifest.operations.privilegedService.dryRunRequired) ([string]$manifest.operations.privilegedService.dryRunRequired)
        Add-Check "manifest:service-self-check" ($manifest.operations.serviceSelfCheck.command -eq "service\samhain-service.exe self-check") ([string]$manifest.operations.serviceSelfCheck.command)
        Add-Check "manifest:desktop-integration-owner" ($manifest.operations.desktopIntegration.owner -eq "local-ops") ([string]$manifest.operations.desktopIntegration.owner)
        Add-Check "manifest:desktop-integration-status-file" ($manifest.operations.desktopIntegration.statusFile -eq "desktop-integration.json") ([string]$manifest.operations.desktopIntegration.statusFile)
        Add-Check "manifest:desktop-integration-link" ($manifest.operations.desktopIntegration.linkHandler -eq "HKCU Software Classes samhain") ([string]$manifest.operations.desktopIntegration.linkHandler)
        Add-Check "manifest:single-instance-handoff" ([bool]$manifest.operations.desktopIntegration.singleInstanceHandoff) ([string]$manifest.operations.desktopIntegration.singleInstanceHandoff)
        Add-Check "manifest:enforcement-transaction" ($manifest.operations.enforcementTransaction.model -eq "typed-apply-rollback") ([string]$manifest.operations.enforcementTransaction.model)
        Add-Check "manifest:enforcement-snapshots" ([bool]$manifest.operations.enforcementTransaction.beforeAfterSnapshots) ([string]$manifest.operations.enforcementTransaction.beforeAfterSnapshots)
        Add-Check "manifest:runtime-contract" ($manifest.operations.runtimeContract.inventory -eq "engine-inventory.json") ([string]$manifest.operations.runtimeContract.inventory)
        Add-Check "manifest:runtime-source" ($manifest.operations.runtimeContract.availabilitySource -eq "package-inventory") ([string]$manifest.operations.runtimeContract.availabilitySource)
        Add-Check "manifest:runtime-layout" ($manifest.operations.runtimeContract.layout.Count -ge 4) "entries=$($manifest.operations.runtimeContract.layout.Count)"
        Add-Check "manifest:runtime-health" ($manifest.quality.runtimeHealthEvidence -eq "service.runtime_health") ([string]$manifest.quality.runtimeHealthEvidence)
        Add-Check "manifest:subscription-operations" ($manifest.quality.subscriptionOperationsEvidence -eq "service.subscription_operations") ([string]$manifest.quality.subscriptionOperationsEvidence)
        Add-Check "manifest:smoke" ($manifest.quality.smokeScript -eq "tools\smoke-package.ps1") ([string]$manifest.quality.smokeScript)
        Add-Check "manifest:update-verifier" ($manifest.quality.updateManifestVerifier -eq "tools\verify-update-manifest.ps1") ([string]$manifest.quality.updateManifestVerifier)
        Add-Check "manifest:release-evidence" ($manifest.quality.releaseEvidenceScript -eq "tools\write-release-evidence.ps1") ([string]$manifest.quality.releaseEvidenceScript)
        Add-Check "manifest:signing-readiness" ($manifest.quality.signingReadinessScript -eq "tools\test-signing-readiness.ps1") ([string]$manifest.quality.signingReadinessScript)
        Add-Check "manifest:clean-machine-evidence" ($manifest.quality.cleanMachineEvidenceScript -eq "tools\write-clean-machine-evidence.ps1") ([string]$manifest.quality.cleanMachineEvidenceScript)
        Add-Check "manifest:signing" ($manifest.signing.digestAlgorithm -eq "SHA256") ([string]$manifest.signing.digestAlgorithm)
    }
    catch {
        Add-Check "manifest:json" $false $_.Exception.Message
    }
}

$engineInventoryPath = Join-Path $PackageRoot "engine-inventory.json"
if (Test-Path $engineInventoryPath) {
    try {
        $engineInventory = @(Get-Content -LiteralPath $engineInventoryPath -Raw | ConvertFrom-Json)
        Add-Check "engine-inventory:json" $true "entries=$($engineInventory.Count)"
        $requiredRuntimeIds = @("sing-box", "xray", "wireguard", "amneziawg")
        foreach ($runtimeId in $requiredRuntimeIds) {
            $entry = $engineInventory | Where-Object { $_.runtimeId -eq $runtimeId } | Select-Object -First 1
            Add-Check "engine-inventory:$runtimeId" ($null -ne $entry) "present=$($null -ne $entry)"
            if ($null -ne $entry) {
                Add-Check "engine-inventory:$runtimeId-path" (-not [string]::IsNullOrWhiteSpace([string]$entry.bundledPath)) ([string]$entry.bundledPath)
                Add-Check "engine-inventory:$runtimeId-protocols" ($entry.protocols.Count -gt 0) "protocols=$($entry.protocols.Count)"
                Add-Check "engine-inventory:$runtimeId-status" ([string]$entry.status -in @("available", "missing")) ([string]$entry.status)
                if ([bool]$entry.available) {
                    Add-Check "engine-inventory:$runtimeId-sha256" (([string]$entry.sha256) -match '^[a-f0-9]{64}$') ([string]$entry.sha256)
                    Add-Check "engine-inventory:$runtimeId-size" ([int64]$entry.fileSizeBytes -gt 0) "size=$($entry.fileSizeBytes)"
                }
            }
        }
    }
    catch {
        Add-Check "engine-inventory:json" $false $_.Exception.Message
    }
}

$checksumPath = Join-Path $PackageRoot "checksums.txt"
if (Test-Path $checksumPath) {
    $checksumLines = Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Add-Check "checksums:present" ($checksumLines.Count -ge 12) "entries=$($checksumLines.Count)"

    foreach ($line in $checksumLines) {
        if ($line -notmatch '^(?<hash>[a-fA-F0-9]{64})\s+(?<relative>.+)$') {
            Add-Check "checksum:format" $false $line
            continue
        }

        $expectedHash = $Matches.hash.ToLowerInvariant()
        $relativePath = $Matches.relative.Trim()
        $targetPath = Join-Path $PackageRoot $relativePath
        if (-not (Test-Path $targetPath)) {
            Add-Check "checksum:$relativePath" $false "missing"
            continue
        }

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash.ToLowerInvariant()
        Add-Check "checksum:$relativePath" ($actualHash -eq $expectedHash) "expected=$expectedHash actual=$actualHash"
    }
}

if ($RunServiceStatus) {
    $serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
    if (Test-Path $serviceExe) {
        $serviceOutput = & $serviceExe status 2>&1
        $serviceExitCode = $LASTEXITCODE
        Add-Check "service:status-exit" ($serviceExitCode -eq 0) "exit=$serviceExitCode"

        try {
            $serviceState = ($serviceOutput | Out-String).Trim() | ConvertFrom-Json
            Add-Check "service:status-json" $true "parsed"
            Add-Check "service:status-version" ($serviceState.version -eq $packageVersion) "service=$($serviceState.version) file=$packageVersion"
            Add-Check "service:readiness-present" ($null -ne $serviceState.service_readiness) "readiness=$($serviceState.service_readiness.status)"
            if ($null -ne $serviceState.service_readiness) {
                Add-Check "service:readiness-identity" (-not [string]::IsNullOrWhiteSpace($serviceState.service_readiness.identity)) ([string]$serviceState.service_readiness.identity)
                Add-Check "service:readiness-signing" ($null -ne $serviceState.service_readiness.signing_state) ([string]$serviceState.service_readiness.signing_state)
                Add-Check "service:readiness-policy" ($null -ne $serviceState.service_readiness.privileged_policy_allowed) "allowed=$($serviceState.service_readiness.privileged_policy_allowed)"
                Add-Check "service:readiness-recovery" ($serviceState.service_readiness.recovery_policy -eq "service-owned") ([string]$serviceState.service_readiness.recovery_policy)
                Add-Check "service:firewall-evidence" ($null -ne $serviceState.service_readiness.firewall_enforcement_available) "available=$($serviceState.service_readiness.firewall_enforcement_available)"
                Add-Check "service:app-routing-evidence" ($null -ne $serviceState.service_readiness.app_routing_enforcement_available) "available=$($serviceState.service_readiness.app_routing_enforcement_available)"
            }
            Add-Check "service:self-check-present" ($null -ne $serviceState.service_self_check) "status=$($serviceState.service_self_check.status)"
            if ($null -ne $serviceState.service_self_check) {
                Add-Check "service:self-check-named-pipe" (($serviceState.service_self_check.checks | Where-Object { $_.name -eq "named-pipe" -and $_.ok }).Count -gt 0) "checks=$($serviceState.service_self_check.checks.Count)"
                Add-Check "service:self-check-firewall" (($serviceState.service_self_check.checks | Where-Object { $_.name -eq "firewall" }).Count -gt 0) "checks=$($serviceState.service_self_check.checks.Count)"
            }
            Add-Check "service:recovery-policy" (($null -ne $serviceState.recovery_policy) -and ($serviceState.recovery_policy.owner -eq "service")) "owner=$($serviceState.recovery_policy.owner)"
            Add-Check "service:audit-events" ($null -ne $serviceState.audit_events) "count=$($serviceState.audit_events.Count)"
            Add-Check "service:engine-inventory" (($null -ne $serviceState.engine_catalog) -and ($serviceState.engine_catalog.Count -ge 4)) "count=$($serviceState.engine_catalog.Count)"
            if (($null -ne $serviceState.engine_catalog) -and ($serviceState.engine_catalog.Count -ge 4)) {
                $singBox = $serviceState.engine_catalog | Where-Object { $_.runtime_id -eq "sing-box" } | Select-Object -First 1
                Add-Check "service:engine-contract-sing-box" (($null -ne $singBox) -and (-not [string]::IsNullOrWhiteSpace([string]$singBox.bundled_path))) ([string]$singBox.bundled_path)
            }
            Add-Check "service:runtime-health" ($null -ne $serviceState.runtime_health) "status=$($serviceState.runtime_health.status)"
            if ($null -ne $serviceState.runtime_health) {
                Add-Check "service:runtime-health-source" (-not [string]::IsNullOrWhiteSpace([string]$serviceState.runtime_health.metrics_source)) ([string]$serviceState.runtime_health.metrics_source)
                Add-Check "service:runtime-health-path" (-not [string]::IsNullOrWhiteSpace([string]$serviceState.runtime_health.route_path)) ([string]$serviceState.runtime_health.route_path)
            }
            Add-Check "service:subscription-operations" ($null -ne $serviceState.subscription_operations) "status=$($serviceState.subscription_operations.status)"
            if ($null -ne $serviceState.subscription_operations) {
                Add-Check "service:subscription-timeout" ([int]$serviceState.subscription_operations.timeout_ms -gt 0) "timeout=$($serviceState.subscription_operations.timeout_ms)"
                Add-Check "service:subscription-deterministic" ([bool]$serviceState.subscription_operations.deterministic) "deterministic=$($serviceState.subscription_operations.deterministic)"
            }
            $transaction = $serviceState.protection_policy.transaction
            Add-Check "service:protection-transaction" ($null -ne $transaction) "status=$($transaction.status)"
            if ($null -ne $transaction) {
                $rollbackSteps = @($transaction.steps | Where-Object { ($null -ne $_.rollback_command) -and ($_.rollback_command.Count -gt 0) })
                Add-Check "service:protection-transaction-id" (-not [string]::IsNullOrWhiteSpace($transaction.id)) ([string]$transaction.id)
                Add-Check "service:protection-transaction-steps" (($transaction.steps.Count -gt 0) -and ($rollbackSteps.Count -gt 0)) "steps=$($transaction.steps.Count) rollback=$($rollbackSteps.Count)"
                Add-Check "service:protection-transaction-snapshots" (($transaction.before_snapshot.Count -gt 0) -and ($transaction.after_snapshot.Count -gt 0)) "before=$($transaction.before_snapshot.Count) after=$($transaction.after_snapshot.Count)"
            }
        }
        catch {
            Add-Check "service:status-json" $false $_.Exception.Message
        }

        try {
            $selfCheckOutput = & $serviceExe self-check 2>&1
            $selfCheckExitCode = $LASTEXITCODE
            Add-Check "service:self-check-exit" ($selfCheckExitCode -eq 0) "exit=$selfCheckExitCode"
            $selfCheck = ($selfCheckOutput | Out-String).Trim() | ConvertFrom-Json
            Add-Check "service:self-check-json" ($null -ne $selfCheck.state) "parsed"
            if ($null -ne $selfCheck.state) {
                Add-Check "service:self-check-recovery" ($selfCheck.state.recovery_policy.owner -eq "service") "owner=$($selfCheck.state.recovery_policy.owner)"
            }
        }
        catch {
            Add-Check "service:self-check-json" $false $_.Exception.Message
        }
    }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    packageVersion = $packageVersion
    checks = $checks
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $checks | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Package validation failed: $PackageRoot"
    }
    else {
        Write-Host "Package validation passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

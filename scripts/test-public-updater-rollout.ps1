param(
    [string]$PackageRoot = "",
    [string]$ManifestPath = "",
    [string]$UpdateManifestPath = "",
    [string]$ExpectedVersion = "",
    [switch]$RequirePublicReady,
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

function Invoke-Tool {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Add-Check $Name $false "missing=$ScriptPath"
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
    if ($detail.Length -gt 700) {
        $detail = $detail.Substring(0, 700)
    }

    Add-Check $Name ($exitCode -eq 0) "exit=$exitCode $detail"
}

function Test-ContainsAll {
    param(
        [object[]]$Values,
        [string[]]$Required
    )

    foreach ($requiredValue in $Required) {
        if ($Values -notcontains $requiredValue) {
            return $false
        }
    }

    return $true
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PackageRoot "release-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($UpdateManifestPath)) {
    $UpdateManifestPath = "$PackageRoot.update-manifest.json"
}

$ManifestPath = [System.IO.Path]::GetFullPath((Resolve-Path $ManifestPath -ErrorAction Stop))
$UpdateManifestPath = [System.IO.Path]::GetFullPath((Resolve-Path $UpdateManifestPath -ErrorAction Stop))
$toolsRoot = Join-Path $PackageRoot "tools"
$signingScript = Join-Path $toolsRoot "test-signing-readiness.ps1"
$privilegedServiceReadinessScript = Join-Path $toolsRoot "test-privileged-service-readiness.ps1"
$updateRehearsalScript = Join-Path $toolsRoot "test-update-rehearsal.ps1"
$checks = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$failed = $false
$packageVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$updateManifest = Get-Content -LiteralPath $UpdateManifestPath -Raw | ConvertFrom-Json
$publicUpdater = $manifest.releaseReadiness.publicUpdater
$publicRollout = $updateManifest.publicRollout
$rolloutGate = "tools\test-public-updater-rollout.ps1"
$requiredEvidence = @(
    "installer-skeleton",
    "signing-readiness",
    "privileged-service-readiness",
    "update-rehearsal",
    "clean-machine-evidence",
    "release-evidence"
)
$requiredInstallerOwns = @(
    "production-signing",
    "elevation",
    "program-files-install",
    "service-registration",
    "update-apply",
    "machine-rollback"
)
$requiredPackageOwns = @(
    "manifest-verification",
    "archive-hash",
    "local-update-rehearsal",
    "current-user-fallback",
    "release-evidence"
)

Add-Check "version:expected" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
Add-Check "manifest:version" ($manifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($manifest.version)"
Add-Check "update-manifest:version" ($updateManifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($updateManifest.version)"
Add-Check "manifest:quality-script" ($manifest.quality.publicUpdaterRolloutScript -eq $rolloutGate) ([string]$manifest.quality.publicUpdaterRolloutScript)
Add-Check "manifest:quality-gate" ($manifest.quality.gates -contains $rolloutGate) "gates=$($manifest.quality.gates -join ',')"
Add-Check "update-manifest:verification-script" ($updateManifest.verification.publicUpdaterRolloutScript -eq $rolloutGate) ([string]$updateManifest.verification.publicUpdaterRolloutScript)

Add-Check "public-updater:present" ($null -ne $publicUpdater) "present=$($null -ne $publicUpdater)"
Add-Check "public-rollout:present" ($null -ne $publicRollout) "present=$($null -ne $publicRollout)"

if ($null -ne $publicUpdater) {
    Add-Check "public-updater:status" ($publicUpdater.status -eq "blocked-until-production-signed-installer") ([string]$publicUpdater.status)
    Add-Check "public-updater:publish-flag" (-not [bool]$publicUpdater.publishAllowed) ([string]$publicUpdater.publishAllowed)
    Add-Check "public-updater:requires-signing" ([bool]$publicUpdater.requiresProductionSigning) ([string]$publicUpdater.requiresProductionSigning)
    Add-Check "public-updater:handoff" ($publicUpdater.installerHandoff -eq "signed-installer-required") ([string]$publicUpdater.installerHandoff)
    Add-Check "public-updater:rollout-gate" ($publicUpdater.rolloutGate -eq $rolloutGate) ([string]$publicUpdater.rolloutGate)
    Add-Check "public-updater:required-evidence" (Test-ContainsAll -Values @($publicUpdater.requiredEvidence) -Required $requiredEvidence) "evidence=$($publicUpdater.requiredEvidence -join ',')"
    Add-Check "public-updater:installer-owns" (Test-ContainsAll -Values @($publicUpdater.handoffBoundary.installerOwns) -Required $requiredInstallerOwns) "installer=$($publicUpdater.handoffBoundary.installerOwns -join ',')"
    Add-Check "public-updater:package-owns" (Test-ContainsAll -Values @($publicUpdater.handoffBoundary.packageOwns) -Required $requiredPackageOwns) "package=$($publicUpdater.handoffBoundary.packageOwns -join ',')"
    Add-Check "public-updater:blocked-when-unsigned" ([bool]$publicUpdater.handoffBoundary.blockedWhenUnsigned) ([string]$publicUpdater.handoffBoundary.blockedWhenUnsigned)
}

if ($null -ne $publicRollout) {
    Add-Check "public-rollout:status" ($publicRollout.status -eq "blocked-until-production-signed-installer") ([string]$publicRollout.status)
    Add-Check "public-rollout:publish-flag" (-not [bool]$publicRollout.publishAllowed) ([string]$publicRollout.publishAllowed)
    Add-Check "public-rollout:requires-signing" ([bool]$publicRollout.requiresProductionSigning) ([string]$publicRollout.requiresProductionSigning)
    Add-Check "public-rollout:handoff" ($publicRollout.installerHandoff -eq "signed-installer-required") ([string]$publicRollout.installerHandoff)
    Add-Check "public-rollout:rollout-gate" ($publicRollout.rolloutGate -eq $rolloutGate) ([string]$publicRollout.rolloutGate)
    Add-Check "public-rollout:required-evidence" (Test-ContainsAll -Values @($publicRollout.requiredEvidence) -Required $requiredEvidence) "evidence=$($publicRollout.requiredEvidence -join ',')"
}

$productionSigned = ($manifest.signing.status -eq "signed-production") -and ($updateManifest.verification.signingStatus -eq "signed-production")
$publishAllowed = ([bool]$publicUpdater.publishAllowed) -and ([bool]$publicRollout.publishAllowed)
Add-Check "signing:declared-production" ((-not $productionSigned) -or $publishAllowed -or (-not [bool]$RequirePublicReady)) "production=$productionSigned publish=$publishAllowed"

if ($RequirePublicReady) {
    Add-Check "public-ready:production-signed" $productionSigned "manifest=$($manifest.signing.status) update=$($updateManifest.verification.signingStatus)"
    Add-Check "public-ready:publish-allowed" $publishAllowed "publish=$publishAllowed"
}
else {
    Add-Check "public-ready:gated-unsigned" ((-not $productionSigned) -and (-not $publishAllowed)) "production=$productionSigned publish=$publishAllowed"
    $warnings.Add("Public updater rollout is intentionally blocked until production signing and signed-installer handoff are available.") | Out-Null
}

Invoke-Tool -Name "gate:signing-readiness" -ScriptPath $signingScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-Tool -Name "gate:privileged-service-readiness" -ScriptPath $privilegedServiceReadinessScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-Tool -Name "gate:update-rehearsal" -ScriptPath $updateRehearsalScript -Parameters @{
    PackageRoot = $PackageRoot
    ManifestPath = $UpdateManifestPath
    ExpectedVersion = $ExpectedVersion
    Json = $true
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    manifestPath = $ManifestPath
    updateManifestPath = $UpdateManifestPath
    version = $ExpectedVersion
    requirePublicReady = [bool]$RequirePublicReady
    productionSigned = $productionSigned
    publishAllowed = $publishAllowed
    status = if ($publicUpdater) { [string]$publicUpdater.status } else { "missing" }
    rolloutGate = $rolloutGate
    checks = $checks
    warnings = $warnings
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 7
}
else {
    $checks | Format-Table -AutoSize
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:"
        $warnings | ForEach-Object { Write-Host "- $_" }
    }
    if ($failed) {
        Write-Host "Public updater rollout gate failed: $PackageRoot"
    }
    else {
        Write-Host "Public updater rollout gate passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

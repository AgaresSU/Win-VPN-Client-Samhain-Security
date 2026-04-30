param(
    [string]$ManifestPath = "",
    [string]$ArchivePath = "",
    [string]$ExpectedVersion = "",
    [string]$InstalledVersion = "",
    [switch]$RequireStableChannel,
    [switch]$AllowDowngradeRecovery,
    [switch]$SkipExtractedPackageValidation,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Resolve-DefaultManifest {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $repoRoot = Resolve-Path (Join-Path $scriptDir "..") -ErrorAction SilentlyContinue
    if (-not $repoRoot -and (Split-Path -Leaf $scriptDir) -eq "tools") {
        $repoRoot = Resolve-Path (Join-Path $scriptDir "..\..") -ErrorAction SilentlyContinue
    }

    if (-not $repoRoot) {
        throw "Manifest path was not supplied and repository root could not be inferred."
    }

    $distRoot = Join-Path $repoRoot "dist"
    $latest = Get-ChildItem -Path $distRoot -File -Filter "*.update-manifest.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "Manifest path was not supplied and no update manifest was found in $distRoot"
    }

    return $latest.FullName
}

function Assert-UnderTemp {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside temp: $fullPath"
    }
}

function Compare-VersionString {
    param(
        [string]$Left,
        [string]$Right
    )

    try {
        $leftVersion = [version]$Left
        $rightVersion = [version]$Right
        return $leftVersion.CompareTo($rightVersion)
    }
    catch {
        return [string]::Compare($Left, $Right, $true, [Globalization.CultureInfo]::InvariantCulture)
    }
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Resolve-DefaultManifest
}

$ManifestPath = [System.IO.Path]::GetFullPath((Resolve-Path $ManifestPath -ErrorAction Stop))
$manifestRoot = Split-Path -Parent $ManifestPath
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $manifestRoot ([string]$manifest.package.fileName)
}

$ArchivePath = [System.IO.Path]::GetFullPath((Resolve-Path $ArchivePath -ErrorAction Stop))
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

Add-Check "manifest:product" ($manifest.product -eq "Samhain Security Native") ([string]$manifest.product)
Add-Check "manifest:channel" ($manifest.channel -in @("release-candidate", "stable")) ([string]$manifest.channel)
if ($RequireStableChannel) {
    Add-Check "manifest:stable-channel" ($manifest.channel -eq "stable") ([string]$manifest.channel)
}
Add-Check "manifest:algorithm" ($manifest.package.algorithm -eq "SHA256") ([string]$manifest.package.algorithm)
Add-Check "manifest:runtime-contract" ($manifest.install.runtimeContract.inventory -eq "engine-inventory.json") ([string]$manifest.install.runtimeContract.inventory)
Add-Check "manifest:runtime-lock" ($manifest.install.runtimeContract.lock -eq "runtime-bundle.lock.json") ([string]$manifest.install.runtimeContract.lock)
Add-Check "manifest:runtime-state" ($manifest.install.runtimeContract.state -eq "app\engines\runtime-bundle-state.json") ([string]$manifest.install.runtimeContract.state)
Add-Check "manifest:runtime-prepare-script" ($manifest.install.runtimeContract.prepareScript -eq "tools\prepare-runtime-bundle.ps1") ([string]$manifest.install.runtimeContract.prepareScript)
Add-Check "manifest:runtime-fetch-script" ($manifest.install.runtimeContract.fetchScript -eq "tools\fetch-runtime-bundle.ps1") ([string]$manifest.install.runtimeContract.fetchScript)
Add-Check "manifest:runtime-source" ($manifest.install.runtimeContract.availabilitySource -eq "package-inventory") ([string]$manifest.install.runtimeContract.availabilitySource)
Add-Check "manifest:engine-inventory" ($manifest.verification.engineInventory -eq "engine-inventory.json") ([string]$manifest.verification.engineInventory)
Add-Check "manifest:runtime-bundle-lock" ($manifest.verification.runtimeBundleLock -eq "runtime-bundle.lock.json") ([string]$manifest.verification.runtimeBundleLock)
Add-Check "manifest:runtime-bundle-state" ($manifest.verification.runtimeBundleState -eq "app\engines\runtime-bundle-state.json") ([string]$manifest.verification.runtimeBundleState)
Add-Check "manifest:runtime-bundle-script" ($manifest.verification.runtimeBundleScript -eq "tools\prepare-runtime-bundle.ps1") ([string]$manifest.verification.runtimeBundleScript)
Add-Check "manifest:runtime-bundle-fetch-script" ($manifest.verification.runtimeBundleFetchScript -eq "tools\fetch-runtime-bundle.ps1") ([string]$manifest.verification.runtimeBundleFetchScript)
Add-Check "manifest:runtime-health" ($manifest.verification.runtimeHealthEvidence -eq "service.runtime_health") ([string]$manifest.verification.runtimeHealthEvidence)
Add-Check "manifest:subscription-operations" ($manifest.verification.subscriptionOperationsEvidence -eq "service.subscription_operations") ([string]$manifest.verification.subscriptionOperationsEvidence)
Add-Check "manifest:proxy-path-smoke" ($manifest.verification.proxyPathSmokeScript -eq "tools\smoke-proxy-path.ps1") ([string]$manifest.verification.proxyPathSmokeScript)
Add-Check "manifest:tun-path-smoke" ($manifest.verification.tunPathSmokeScript -eq "tools\smoke-tun-path.ps1") ([string]$manifest.verification.tunPathSmokeScript)
Add-Check "manifest:release-notes-script" ($manifest.verification.releaseNotesScript -eq "tools\write-release-notes.ps1") ([string]$manifest.verification.releaseNotesScript)
Add-Check "manifest:release-readiness-status" ($manifest.releaseReadiness.status -eq "release-ready-dev-signed") ([string]$manifest.releaseReadiness.status)
Add-Check "manifest:release-readiness-protocol-doc" ($manifest.releaseReadiness.protocolMatrix -eq "docs\PROTOCOL_MATRIX.md") ([string]$manifest.releaseReadiness.protocolMatrix)
Add-Check "manifest:release-readiness-visual-doc" ($manifest.releaseReadiness.visualQa -eq "docs\VISUAL_QA.md") ([string]$manifest.releaseReadiness.visualQa)

$policy = $manifest.updatePolicy
Add-Check "manifest:update-policy" ($null -ne $policy) "present=$($null -ne $policy)"
Add-Check "manifest:update-policy-hash" ($policy.trustedHashAlgorithm -eq "SHA256") ([string]$policy.trustedHashAlgorithm)
Add-Check "manifest:update-policy-downgrade" ([bool]$policy.downgradeProtection) ([string]$policy.downgradeProtection)
Add-Check "manifest:update-policy-minimum-version" (-not [string]::IsNullOrWhiteSpace([string]$policy.minimumSupportedVersion)) ([string]$policy.minimumSupportedVersion)
Add-Check "manifest:update-policy-explicit-recovery" ([bool]$policy.explicitRecoveryRequired) ([string]$policy.explicitRecoveryRequired)
Add-Check "manifest:update-policy-rollback-preserve" ([bool]$policy.rollback.preservePreviousPackage) ([string]$policy.rollback.preservePreviousPackage)
Add-Check "manifest:update-policy-rollback-state" ($policy.rollback.stateFile -eq "rollback-state.json") ([string]$policy.rollback.stateFile)
Add-Check "manifest:update-policy-rollback-owner" ($policy.rollback.owner -eq "local-ops") ([string]$policy.rollback.owner)

if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
    $comparison = Compare-VersionString -Left ([string]$manifest.version) -Right $InstalledVersion
    $isDowngrade = $comparison -lt 0
    $downgradeAllowed = (-not $isDowngrade) -or [bool]$AllowDowngradeRecovery
    Add-Check "manifest:update-policy-downgrade-guard" $downgradeAllowed "installed=$InstalledVersion candidate=$($manifest.version) recovery=$([bool]$AllowDowngradeRecovery)"
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    Add-Check "manifest:expected-version" ($manifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($manifest.version)"
}

$archiveInfo = Get-Item -LiteralPath $ArchivePath
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
$expectedHash = ([string]$manifest.package.sha256).ToLowerInvariant()
$expectedSize = [int64]$manifest.package.sizeBytes

Add-Check "archive:file-name" ($archiveInfo.Name -eq $manifest.package.fileName) "manifest=$($manifest.package.fileName) actual=$($archiveInfo.Name)"
Add-Check "archive:size" ($archiveInfo.Length -eq $expectedSize) "expected=$expectedSize actual=$($archiveInfo.Length)"
Add-Check "archive:sha256" ($archiveHash -eq $expectedHash) "expected=$expectedHash actual=$archiveHash"

if (-not $SkipExtractedPackageValidation) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("SamhainSecurityVerify-" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $tempRoot -Force

        $versionPath = Join-Path $tempRoot "VERSION"
        $releaseManifestPath = Join-Path $tempRoot "release-manifest.json"
        Add-Check "archive:version-file" (Test-Path $versionPath) $versionPath
        Add-Check "archive:release-manifest" (Test-Path $releaseManifestPath) $releaseManifestPath

        if (Test-Path $versionPath) {
            $archiveVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
            Add-Check "archive:version" ($archiveVersion -eq $manifest.version) "manifest=$($manifest.version) archive=$archiveVersion"
        }

        $validatorPath = Join-Path $tempRoot "tools\validate-package.ps1"
        if (Test-Path $validatorPath) {
            $validationOutput = & $validatorPath -PackageRoot $tempRoot -ExpectedVersion ([string]$manifest.version) -RunServiceStatus -Json *>&1
            $validationExitCode = $LASTEXITCODE
            Add-Check "archive:validate-package" ($validationExitCode -eq 0) "exit=$validationExitCode $((($validationOutput | Out-String).Trim()).Substring(0, [Math]::Min(240, (($validationOutput | Out-String).Trim()).Length)))"
        }
        else {
            Add-Check "archive:validate-package" $false "missing=$validatorPath"
        }
    }
    finally {
        if (Test-Path $tempRoot) {
            Assert-UnderTemp $tempRoot
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    manifestPath = $ManifestPath
    archivePath = $ArchivePath
    version = [string]$manifest.version
    checks = $checks
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $checks | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Update manifest verification failed: $ManifestPath"
    }
    else {
        Write-Host "Update manifest verification passed: $ManifestPath"
    }
}

if ($failed) {
    exit 1
}

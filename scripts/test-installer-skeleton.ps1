param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [switch]$RequireProductionSigning,
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

$checks = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$failed = $false
$versionPath = Join-Path $PackageRoot "VERSION"
$manifestPath = Join-Path $PackageRoot "release-manifest.json"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$installerRoot = Join-Path $PackageRoot "installer"
$readmePath = Join-Path $installerRoot "README.md"
$wixPath = Join-Path $installerRoot "SamhainSecurityInstaller.wxs"
$buildPlanPath = Join-Path $installerRoot "installer-build-plan.json"
$signingPolicyPath = Join-Path $installerRoot "signing-policy.json"
$handoffPath = Join-Path $installerRoot "installer-handoff.json"
$packageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
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
$requiredEvidence = @(
    "installer-skeleton",
    "installer-toolchain",
    "signing-readiness",
    "privileged-service-readiness",
    "update-rehearsal",
    "clean-machine-evidence",
    "release-evidence"
)

Add-Check "version:expected" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
Add-Check "installer:root" (Test-Path -LiteralPath $installerRoot) $installerRoot
Add-Check "installer:readme" (Test-Path -LiteralPath $readmePath) $readmePath
Add-Check "installer:wix" (Test-Path -LiteralPath $wixPath) $wixPath
Add-Check "installer:build-plan" (Test-Path -LiteralPath $buildPlanPath) $buildPlanPath
Add-Check "installer:signing-policy" (Test-Path -LiteralPath $signingPolicyPath) $signingPolicyPath
Add-Check "installer:handoff" (Test-Path -LiteralPath $handoffPath) $handoffPath
Add-Check "manifest:exists" (Test-Path -LiteralPath $manifestPath) $manifestPath
Add-Check "update-manifest:exists" (Test-Path -LiteralPath $updateManifestPath) $updateManifestPath

$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Add-Check "manifest:version" ($manifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($manifest.version)"
    Add-Check "manifest:installer-script" ($manifest.quality.installerSkeletonScript -eq "tools\test-installer-skeleton.ps1") ([string]$manifest.quality.installerSkeletonScript)
    Add-Check "manifest:installer-gate" ($manifest.quality.gates -contains "tools\test-installer-skeleton.ps1") "gates=$($manifest.quality.gates -join ',')"
    Add-Check "manifest:installer-status" ($manifest.releaseReadiness.installer.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$manifest.releaseReadiness.installer.status)
    Add-Check "manifest:installer-project" ($manifest.releaseReadiness.installer.project -eq "installer\SamhainSecurityInstaller.wxs") ([string]$manifest.releaseReadiness.installer.project)
    Add-Check "manifest:installer-signing-policy" ($manifest.releaseReadiness.installer.signingPolicy -eq "installer\signing-policy.json") ([string]$manifest.releaseReadiness.installer.signingPolicy)
    Add-Check "manifest:installer-build-plan" ($manifest.releaseReadiness.installer.buildPlan -eq "installer\installer-build-plan.json") ([string]$manifest.releaseReadiness.installer.buildPlan)
    Add-Check "manifest:installer-preflight" ($manifest.releaseReadiness.installer.preflight -eq "tools\test-installer-toolchain.ps1") ([string]$manifest.releaseReadiness.installer.preflight)
    Add-Check "manifest:installer-skeleton-preflight" ($manifest.releaseReadiness.installer.skeletonPreflight -eq "tools\test-installer-skeleton.ps1") ([string]$manifest.releaseReadiness.installer.skeletonPreflight)
    Add-Check "manifest:installer-toolchain-preflight" ($manifest.releaseReadiness.installer.toolchainPreflight -eq "tools\test-installer-toolchain.ps1") ([string]$manifest.releaseReadiness.installer.toolchainPreflight)
    Add-Check "manifest:installer-publish-blocked" (-not [bool]$manifest.releaseReadiness.installer.publishAllowed) ([string]$manifest.releaseReadiness.installer.publishAllowed)
    Add-Check "manifest:installer-production-signing" ([bool]$manifest.releaseReadiness.installer.requiresProductionSigning) ([string]$manifest.releaseReadiness.installer.requiresProductionSigning)
}

$updateManifest = $null
if (Test-Path -LiteralPath $updateManifestPath) {
    $updateManifest = Get-Content -LiteralPath $updateManifestPath -Raw | ConvertFrom-Json
    Add-Check "update-manifest:version" ($updateManifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($updateManifest.version)"
    Add-Check "update-manifest:installer-script" ($updateManifest.verification.installerSkeletonScript -eq "tools\test-installer-skeleton.ps1") ([string]$updateManifest.verification.installerSkeletonScript)
    Add-Check "update-manifest:installer-status" ($updateManifest.signedInstaller.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$updateManifest.signedInstaller.status)
    Add-Check "update-manifest:installer-project" ($updateManifest.signedInstaller.project -eq "installer\SamhainSecurityInstaller.wxs") ([string]$updateManifest.signedInstaller.project)
    Add-Check "update-manifest:installer-signing-policy" ($updateManifest.signedInstaller.signingPolicy -eq "installer\signing-policy.json") ([string]$updateManifest.signedInstaller.signingPolicy)
    Add-Check "update-manifest:installer-build-plan" ($updateManifest.signedInstaller.buildPlan -eq "installer\installer-build-plan.json") ([string]$updateManifest.signedInstaller.buildPlan)
    Add-Check "update-manifest:installer-preflight" ($updateManifest.signedInstaller.preflight -eq "tools\test-installer-toolchain.ps1") ([string]$updateManifest.signedInstaller.preflight)
    Add-Check "update-manifest:installer-skeleton-preflight" ($updateManifest.signedInstaller.skeletonPreflight -eq "tools\test-installer-skeleton.ps1") ([string]$updateManifest.signedInstaller.skeletonPreflight)
    Add-Check "update-manifest:installer-toolchain-preflight" ($updateManifest.signedInstaller.toolchainPreflight -eq "tools\test-installer-toolchain.ps1") ([string]$updateManifest.signedInstaller.toolchainPreflight)
    Add-Check "update-manifest:installer-publish-blocked" (-not [bool]$updateManifest.signedInstaller.publishAllowed) ([string]$updateManifest.signedInstaller.publishAllowed)
    Add-Check "update-manifest:installer-production-signing" ([bool]$updateManifest.signedInstaller.requiresProductionSigning) ([string]$updateManifest.signedInstaller.requiresProductionSigning)
}

if (Test-Path -LiteralPath $wixPath) {
    try {
        [xml]$wix = Get-Content -LiteralPath $wixPath -Raw
        $rawWix = Get-Content -LiteralPath $wixPath -Raw
        Add-Check "wix:xml" ($wix.DocumentElement.LocalName -eq "Wix") $wix.DocumentElement.LocalName
        Add-Check "wix:package-name" ($rawWix -like '*Name="Samhain Security"*') "name=Samhain Security"
        Add-Check "wix:service-install" ($rawWix -like '*ServiceInstall*' -and $rawWix -like '*SamhainSecurityService*') "service=SamhainSecurityService"
        Add-Check "wix:program-files" ($rawWix -like '*ProgramFiles64Folder*' -and $rawWix -like '*SamhainSecurity*') "programFiles=True"
    }
    catch {
        Add-Check "wix:xml" $false $_.Exception.Message
    }
}

$buildPlan = $null
if (Test-Path -LiteralPath $buildPlanPath) {
    try {
        $buildPlan = Get-Content -LiteralPath $buildPlanPath -Raw | ConvertFrom-Json
        Add-Check "build-plan:schema" ($buildPlan.schema -eq "samhain.installerBuildPlan") ([string]$buildPlan.schema)
        Add-Check "build-plan:version" ($buildPlan.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($buildPlan.version)"
        Add-Check "build-plan:status" ($buildPlan.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$buildPlan.status)
        Add-Check "build-plan:script" ($buildPlan.unsignedDryRun.script -eq "tools\test-installer-toolchain.ps1") ([string]$buildPlan.unsignedDryRun.script)
        Add-Check "build-plan:publish-blocked" (-not [bool]$buildPlan.unsignedDryRun.publishAllowed) ([string]$buildPlan.unsignedDryRun.publishAllowed)
        Add-Check "build-plan:requires-production" ([bool]$buildPlan.unsignedDryRun.requiresProductionSigning) ([string]$buildPlan.unsignedDryRun.requiresProductionSigning)
    }
    catch {
        Add-Check "build-plan:json" $false $_.Exception.Message
    }
}

$signingPolicy = $null
if (Test-Path -LiteralPath $signingPolicyPath) {
    try {
        $signingPolicy = Get-Content -LiteralPath $signingPolicyPath -Raw | ConvertFrom-Json
        Add-Check "signing-policy:schema" ($signingPolicy.schema -eq "samhain.signingPolicy") ([string]$signingPolicy.schema)
        Add-Check "signing-policy:version" ($signingPolicy.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($signingPolicy.version)"
        Add-Check "signing-policy:publisher" ($signingPolicy.expectedPublisher -eq "Samhain Security") ([string]$signingPolicy.expectedPublisher)
        Add-Check "signing-policy:digest" ($signingPolicy.digestAlgorithm -eq "SHA256") ([string]$signingPolicy.digestAlgorithm)
        Add-Check "signing-policy:timestamp" ([bool]$signingPolicy.timestampRequired) ([string]$signingPolicy.timestampRequired)
        Add-Check "signing-policy:publish-blocked" (-not [bool]$signingPolicy.publicRelease.publishAllowed) ([string]$signingPolicy.publicRelease.publishAllowed)
        Add-Check "signing-policy:requires-production" ([bool]$signingPolicy.publicRelease.productionSigningRequired) ([string]$signingPolicy.publicRelease.productionSigningRequired)
        $targetIds = @($signingPolicy.targets | ForEach-Object { [string]$_.id })
        Add-Check "signing-policy:targets" (Test-ContainsAll -Values $targetIds -Required @("desktop", "service", "installer")) "targets=$($targetIds -join ',')"
    }
    catch {
        Add-Check "signing-policy:json" $false $_.Exception.Message
    }
}

$handoff = $null
if (Test-Path -LiteralPath $handoffPath) {
    try {
        $handoff = Get-Content -LiteralPath $handoffPath -Raw | ConvertFrom-Json
        Add-Check "handoff:schema" ($handoff.schema -eq "samhain.installerHandoff") ([string]$handoff.schema)
        Add-Check "handoff:version" ($handoff.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($handoff.version)"
        Add-Check "handoff:status" ($handoff.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$handoff.status)
        Add-Check "handoff:project" ($handoff.installerProject -eq "installer\SamhainSecurityInstaller.wxs") ([string]$handoff.installerProject)
        Add-Check "handoff:policy" ($handoff.signingPolicy -eq "installer\signing-policy.json") ([string]$handoff.signingPolicy)
        Add-Check "handoff:build-plan" ($handoff.buildPlan -eq "installer\installer-build-plan.json") ([string]$handoff.buildPlan)
        Add-Check "handoff:preflight" ($handoff.preflight -eq "tools\test-installer-toolchain.ps1") ([string]$handoff.preflight)
        Add-Check "handoff:skeleton-preflight" ($handoff.skeletonPreflight -eq "tools\test-installer-skeleton.ps1") ([string]$handoff.skeletonPreflight)
        Add-Check "handoff:toolchain-preflight" ($handoff.toolchainPreflight -eq "tools\test-installer-toolchain.ps1") ([string]$handoff.toolchainPreflight)
        Add-Check "handoff:publish-blocked" (-not [bool]$handoff.publishAllowed) ([string]$handoff.publishAllowed)
        Add-Check "handoff:requires-production" ([bool]$handoff.requiresProductionSigning) ([string]$handoff.requiresProductionSigning)
        Add-Check "handoff:installer-owns" (Test-ContainsAll -Values @($handoff.installerOwns) -Required $requiredInstallerOwns) "installer=$($handoff.installerOwns -join ',')"
        Add-Check "handoff:package-owns" (Test-ContainsAll -Values @($handoff.packageOwns) -Required $requiredPackageOwns) "package=$($handoff.packageOwns -join ',')"
        Add-Check "handoff:public-evidence" (Test-ContainsAll -Values @($handoff.publicRollout.requiredEvidence) -Required $requiredEvidence) "evidence=$($handoff.publicRollout.requiredEvidence -join ',')"
        Add-Check "handoff:service-name" ($handoff.service.name -eq "SamhainSecurityService") ([string]$handoff.service.name)
    }
    catch {
        Add-Check "handoff:json" $false $_.Exception.Message
    }
}

$productionReady = $false
if ($manifest -and $signingPolicy -and $handoff) {
    $productionReady = ($manifest.signing.status -eq "signed-production") -and [bool]$handoff.publishAllowed -and [bool]$signingPolicy.publicRelease.publishAllowed
}

if ($RequireProductionSigning) {
    Add-Check "production-ready:signing" $productionReady "ready=$productionReady"
}
else {
    Add-Check "production-ready:gated" (-not $productionReady) "ready=$productionReady"
    $warnings.Add("Installer skeleton is present, but public publishing remains blocked until production signing is supplied.") | Out-Null
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    requireProductionSigning = [bool]$RequireProductionSigning
    productionReady = $productionReady
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
        Write-Host "Installer skeleton gate failed: $PackageRoot"
    }
    else {
        Write-Host "Installer skeleton gate passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

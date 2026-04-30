param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$CommitSha = "",
    [string]$Tag = "",
    [switch]$SkipSmoke,
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

function Get-GitValue {
    param([string[]]$Arguments)

    try {
        $value = & git @Arguments 2>$null
        if ($LASTEXITCODE -eq 0) {
            return (($value | Out-String).Trim())
        }
    }
    catch {
    }

    return ""
}

function Add-Gate {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    if (-not $Ok) {
        $script:failed = $true
    }

    $script:gates.Add([PSCustomObject]@{
        name = $Name
        ok = $Ok
        detail = $Detail
    }) | Out-Null
}

function Invoke-GateScript {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path $ScriptPath)) {
        Add-Gate $Name $false "missing=$ScriptPath"
        return
    }

    $global:LASTEXITCODE = 0
    $output = & $ScriptPath @Parameters *>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 800) {
        $detail = $detail.Substring(0, 800)
    }

    Add-Gate $Name ($exitCode -eq 0) "exit=$exitCode $detail"
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    $CommitSha = Get-GitValue -Arguments @("rev-parse", "HEAD")
}
if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = Get-GitValue -Arguments @("describe", "--tags", "--exact-match", "HEAD")
}

$toolsRoot = Join-Path $PackageRoot "tools"
$validateScript = Join-Path $toolsRoot "validate-package.ps1"
$verifyScript = Join-Path $toolsRoot "verify-update-manifest.ps1"
$updateRehearsalScript = Join-Path $toolsRoot "test-update-rehearsal.ps1"
$publicUpdaterRolloutScript = Join-Path $toolsRoot "test-public-updater-rollout.ps1"
$smokeScript = Join-Path $toolsRoot "smoke-package.ps1"
$proxyPathSmokeScript = Join-Path $toolsRoot "smoke-proxy-path.ps1"
$tunPathSmokeScript = Join-Path $toolsRoot "smoke-tun-path.ps1"
$adapterPathSmokeScript = Join-Path $toolsRoot "smoke-adapter-path.ps1"
$signingScript = Join-Path $toolsRoot "test-signing-readiness.ps1"
$privilegedServiceReadinessScript = Join-Path $toolsRoot "test-privileged-service-readiness.ps1"
$cleanMachineScript = Join-Path $toolsRoot "write-clean-machine-evidence.ps1"
$releaseNotesScript = Join-Path $toolsRoot "write-release-notes.ps1"
$runtimeBundleScript = Join-Path $toolsRoot "prepare-runtime-bundle.ps1"
$archivePath = "$PackageRoot.zip"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$evidencePath = "$PackageRoot.release-evidence.json"
$releaseNotesPath = "$PackageRoot.release-notes.md"
$runtimeBundleLockPath = Join-Path $PackageRoot "runtime-bundle.lock.json"
$runtimeBundleStatePath = Join-Path $PackageRoot "app\engines\runtime-bundle-state.json"
$gates = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$failed = $false

if (-not (Test-Path $archivePath)) {
    Add-Gate "archive:exists" $false "missing=$archivePath"
}
if (-not (Test-Path $updateManifestPath)) {
    Add-Gate "update-manifest:exists" $false "missing=$updateManifestPath"
}

$updateManifest = $null
if (Test-Path $updateManifestPath) {
    $updateManifest = Get-Content -LiteralPath $updateManifestPath -Raw | ConvertFrom-Json
    Add-Gate "release:stable-channel" ($updateManifest.channel -eq "stable") ([string]$updateManifest.channel)
    Add-Gate "release:expected-version" ($updateManifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($updateManifest.version)"
    Add-Gate "release:update-policy-hash" ($updateManifest.updatePolicy.trustedHashAlgorithm -eq "SHA256") ([string]$updateManifest.updatePolicy.trustedHashAlgorithm)
    Add-Gate "release:update-policy-downgrade" ([bool]$updateManifest.updatePolicy.downgradeProtection) ([string]$updateManifest.updatePolicy.downgradeProtection)
    Add-Gate "release:update-policy-rollback" ([bool]$updateManifest.updatePolicy.rollback.preservePreviousPackage) ([string]$updateManifest.updatePolicy.rollback.preservePreviousPackage)
}

Invoke-GateScript -Name "validate-package" -ScriptPath $validateScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    RunServiceStatus = $true
    Json = $true
}
Invoke-GateScript -Name "runtime-bundle" -ScriptPath $runtimeBundleScript -Parameters @{
    PackageRoot = $PackageRoot
    ValidateOnly = $true
    Json = $true
}
Invoke-GateScript -Name "verify-update-manifest" -ScriptPath $verifyScript -Parameters @{
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    RequireStableChannel = $true
    Json = $true
}
Invoke-GateScript -Name "update-rehearsal" -ScriptPath $updateRehearsalScript -Parameters @{
    PackageRoot = $PackageRoot
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-GateScript -Name "public-updater-rollout" -ScriptPath $publicUpdaterRolloutScript -Parameters @{
    PackageRoot = $PackageRoot
    UpdateManifestPath = $updateManifestPath
    ExpectedVersion = $ExpectedVersion
    Json = $true
}

if ($SkipSmoke) {
    Add-Gate "smoke-package" $true "skipped"
    Add-Gate "proxy-path-smoke" $true "skipped"
    Add-Gate "tun-path-smoke" $true "skipped"
    Add-Gate "adapter-path-smoke" $true "skipped"
}
else {
    Invoke-GateScript -Name "smoke-package" -ScriptPath $smokeScript -Parameters @{
        PackageRoot = $PackageRoot
        ExpectedVersion = $ExpectedVersion
        SkipLaunch = $true
        Json = $true
    }
    Invoke-GateScript -Name "proxy-path-smoke" -ScriptPath $proxyPathSmokeScript -Parameters @{
        PackageRoot = $PackageRoot
        ExpectedVersion = $ExpectedVersion
        Json = $true
    }
    Invoke-GateScript -Name "tun-path-smoke" -ScriptPath $tunPathSmokeScript -Parameters @{
        PackageRoot = $PackageRoot
        ExpectedVersion = $ExpectedVersion
        Json = $true
    }
    Invoke-GateScript -Name "adapter-path-smoke" -ScriptPath $adapterPathSmokeScript -Parameters @{
        PackageRoot = $PackageRoot
        ExpectedVersion = $ExpectedVersion
        Json = $true
    }
}

Invoke-GateScript -Name "signing-readiness" -ScriptPath $signingScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-GateScript -Name "privileged-service-readiness" -ScriptPath $privilegedServiceReadinessScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-GateScript -Name "clean-machine-evidence" -ScriptPath $cleanMachineScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    MatrixCase = "release-evidence-local"
    SkipLaunch = $true
    Json = $true
}
Invoke-GateScript -Name "release-notes" -ScriptPath $releaseNotesScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    OutputPath = $releaseNotesPath
    Json = $true
}

$archive = $null
$archiveHash = ""
if (Test-Path $archivePath) {
    $archive = Get-Item -LiteralPath $archivePath
    $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
}

$signingStatus = ""
if ($updateManifest) {
    $signingStatus = [string]$updateManifest.verification.signingStatus
}
if ($signingStatus -ne "signed-production") {
    $warnings.Add("Production signing certificate is not applied; package remains integrity-verified but unsigned.") | Out-Null
}
if ($updateManifest -and (-not [bool]$updateManifest.publicRollout.publishAllowed)) {
    $warnings.Add("Public updater rollout is blocked until production signing and signed-installer handoff are available.") | Out-Null
}
if ([string]::IsNullOrWhiteSpace($Tag)) {
    $warnings.Add("No exact release tag was detected for the current commit.") | Out-Null
}

$evidence = [PSCustomObject]@{
    ok = -not $failed
    product = "Samhain Security Native"
    version = $ExpectedVersion
    channel = if ($updateManifest) { [string]$updateManifest.channel } else { "" }
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    commitSha = $CommitSha
    tag = $Tag
    packageRoot = $PackageRoot
    archivePath = $archivePath
    updateManifestPath = $updateManifestPath
    releaseNotesPath = $releaseNotesPath
    archive = [PSCustomObject]@{
        fileName = if ($archive) { $archive.Name } else { "" }
        sizeBytes = if ($archive) { $archive.Length } else { 0 }
        sha256 = $archiveHash
    }
    runtimeBundle = [PSCustomObject]@{
        lockPath = $runtimeBundleLockPath
        statePath = $runtimeBundleStatePath
        lockPresent = Test-Path $runtimeBundleLockPath
        statePresent = Test-Path $runtimeBundleStatePath
    }
    signing = [PSCustomObject]@{
        status = $signingStatus
        productionSigned = ($signingStatus -eq "signed-production")
    }
    publicRollout = if ($updateManifest) { $updateManifest.publicRollout } else { $null }
    updatePolicy = if ($updateManifest) { $updateManifest.updatePolicy } else { $null }
    gates = $gates
    warnings = $warnings
}

$evidence | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $evidencePath -Encoding UTF8

if (Test-Path $releaseNotesScript) {
    & $releaseNotesScript -PackageRoot $PackageRoot -ExpectedVersion $ExpectedVersion -OutputPath $releaseNotesPath | Out-Null
}

if ($Json) {
    $evidence | ConvertTo-Json -Depth 7
}
else {
    $gates | Format-Table -AutoSize
    Write-Host "Release evidence: $evidencePath"
}

if ($failed) {
    exit 1
}

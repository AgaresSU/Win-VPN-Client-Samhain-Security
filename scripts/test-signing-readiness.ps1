param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [switch]$RequireProductionSigned,
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

$checks = New-Object System.Collections.Generic.List[object]
$signatures = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
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

$versionPath = Join-Path $PackageRoot "VERSION"
$manifestPath = Join-Path $PackageRoot "release-manifest.json"
$signingPolicyPath = Join-Path $PackageRoot "installer\signing-policy.json"
$packageVersion = ""
if (Test-Path $versionPath) {
    $packageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
}

Add-Check "version:expected" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
Add-Check "manifest:exists" (Test-Path $manifestPath) $manifestPath
Add-Check "signing-policy:exists" (Test-Path $signingPolicyPath) $signingPolicyPath

$manifest = $null
if (Test-Path $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Add-Check "manifest:expected-publisher" ($manifest.signing.expectedPublisher -eq "Samhain Security") ([string]$manifest.signing.expectedPublisher)
    Add-Check "manifest:digest" ($manifest.signing.digestAlgorithm -eq "SHA256") ([string]$manifest.signing.digestAlgorithm)
    Add-Check "manifest:declared-status" ($manifest.signing.status -in @("unsigned-dev", "signed-production")) ([string]$manifest.signing.status)
    Add-Check "manifest:signing-policy" ($manifest.signing.policy -eq "installer\signing-policy.json") ([string]$manifest.signing.policy)
    Add-Check "manifest:installer-handoff" ($manifest.signing.installerHandoff -eq "installer\installer-handoff.json") ([string]$manifest.signing.installerHandoff)
}

if (Test-Path $signingPolicyPath) {
    $policy = Get-Content -LiteralPath $signingPolicyPath -Raw | ConvertFrom-Json
    $targetIds = @($policy.targets | ForEach-Object { [string]$_.id })
    Add-Check "signing-policy:schema" ($policy.schema -eq "samhain.signingPolicy") ([string]$policy.schema)
    Add-Check "signing-policy:version" ($policy.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($policy.version)"
    Add-Check "signing-policy:publisher" ($policy.expectedPublisher -eq "Samhain Security") ([string]$policy.expectedPublisher)
    Add-Check "signing-policy:digest" ($policy.digestAlgorithm -eq "SHA256") ([string]$policy.digestAlgorithm)
    Add-Check "signing-policy:timestamp" ([bool]$policy.timestampRequired) ([string]$policy.timestampRequired)
    Add-Check "signing-policy:desktop-target" ($targetIds -contains "desktop") "targets=$($targetIds -join ',')"
    Add-Check "signing-policy:service-target" ($targetIds -contains "service") "targets=$($targetIds -join ',')"
    Add-Check "signing-policy:installer-target" ($targetIds -contains "installer") "targets=$($targetIds -join ',')"
    Add-Check "signing-policy:publish-blocked" (-not [bool]$policy.publicRelease.publishAllowed) ([string]$policy.publicRelease.publishAllowed)
    Add-Check "signing-policy:production-required" ([bool]$policy.publicRelease.productionSigningRequired) ([string]$policy.publicRelease.productionSigningRequired)
}

$targets = @(
    "app\SamhainSecurityNative.exe",
    "service\samhain-service.exe"
)

foreach ($relative in $targets) {
    $path = Join-Path $PackageRoot $relative
    if (-not (Test-Path $path)) {
        Add-Check "signature:$relative" $false "missing=$path"
        continue
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $path
    $isValid = $signature.Status -eq "Valid"
    $subject = ""
    if ($signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }

    if (-not $isValid) {
        $warnings.Add("$relative signature status is $($signature.Status).") | Out-Null
    }

    $signatures.Add([PSCustomObject]@{
        path = $relative
        status = [string]$signature.Status
        subject = $subject
        thumbprint = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Thumbprint } else { "" }
    }) | Out-Null

    $ok = if ($RequireProductionSigned) { $isValid } else { $true }
    Add-Check "signature:$relative" $ok "status=$($signature.Status)"
}

if ($RequireProductionSigned -and $manifest -and $manifest.signing.status -ne "signed-production") {
    Add-Check "manifest:production-signing" $false ([string]$manifest.signing.status)
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    requireProductionSigned = [bool]$RequireProductionSigned
    signatures = $signatures
    checks = $checks
    warnings = $warnings
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $checks | Format-Table -AutoSize
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:"
        $warnings | ForEach-Object { Write-Host "- $_" }
    }
}

if ($failed) {
    exit 1
}

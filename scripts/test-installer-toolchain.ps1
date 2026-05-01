param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$WixExe = "",
    [string]$OutputRoot = "",
    [switch]$RequireWix,
    [switch]$KeepOutput,
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

function Add-InfoCheck {
    param(
        [string]$Name,
        [string]$Detail
    )

    $script:checks.Add([PSCustomObject]@{
        name = $Name
        ok = $true
        detail = $Detail
    }) | Out-Null
}

function Resolve-WixCommand {
    param(
        [string]$ExplicitPath,
        [string]$PackageRootValue
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add($ExplicitPath) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SAMHAIN_WIX_EXE)) {
        $candidates.Add($env:SAMHAIN_WIX_EXE) | Out-Null
    }

    $locationTool = Join-Path (Get-Location) ".tools\wix\wix.exe"
    $candidates.Add($locationTool) | Out-Null

    $scriptDir = Split-Path -Parent $PSCommandPath
    $repoTool = Join-Path (Join-Path $scriptDir "..") ".tools\wix\wix.exe"
    $candidates.Add($repoTool) | Out-Null

    $packageTool = Join-Path $PackageRootValue "tools\wix.exe"
    $candidates.Add($packageTool) | Out-Null

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [System.IO.Path]::GetFullPath((Resolve-Path $candidate -ErrorAction Stop))
        }
    }

    $global = Get-Command wix -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($global) {
        return [System.IO.Path]::GetFullPath($global.Source)
    }

    return ""
}

function Assert-UnderTemp {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside temp: $fullPath"
    }
}

function Compare-MajorVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0
    }

    $firstLine = (($Value -split "\r?\n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $match = [regex]::Match([string]$firstLine, '(\d+)')
    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }

    return 0
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
$wixSourcePath = Join-Path $installerRoot "SamhainSecurityInstaller.wxs"
$buildPlanPath = Join-Path $installerRoot "installer-build-plan.json"
$signingPolicyPath = Join-Path $installerRoot "signing-policy.json"
$handoffPath = Join-Path $installerRoot "installer-handoff.json"
$packageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()

Add-Check "version:expected" ($packageVersion -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$packageVersion"
Add-Check "installer:wix-source" (Test-Path -LiteralPath $wixSourcePath) $wixSourcePath
Add-Check "installer:build-plan" (Test-Path -LiteralPath $buildPlanPath) $buildPlanPath
Add-Check "installer:signing-policy" (Test-Path -LiteralPath $signingPolicyPath) $signingPolicyPath
Add-Check "installer:handoff" (Test-Path -LiteralPath $handoffPath) $handoffPath
Add-Check "manifest:exists" (Test-Path -LiteralPath $manifestPath) $manifestPath
Add-Check "update-manifest:exists" (Test-Path -LiteralPath $updateManifestPath) $updateManifestPath

$buildPlan = $null
if (Test-Path -LiteralPath $buildPlanPath) {
    try {
        $buildPlan = Get-Content -LiteralPath $buildPlanPath -Raw | ConvertFrom-Json
        Add-Check "build-plan:schema" ($buildPlan.schema -eq "samhain.installerBuildPlan") ([string]$buildPlan.schema)
        Add-Check "build-plan:version" ($buildPlan.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($buildPlan.version)"
        Add-Check "build-plan:status" ($buildPlan.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$buildPlan.status)
        Add-Check "build-plan:tool" ($buildPlan.toolchain.tool -eq "wix") ([string]$buildPlan.toolchain.tool)
        Add-Check "build-plan:preferred-version" (-not [string]::IsNullOrWhiteSpace([string]$buildPlan.toolchain.preferredVersion)) ([string]$buildPlan.toolchain.preferredVersion)
        Add-Check "build-plan:dotnet-major" ([int]$buildPlan.toolchain.minimumDotnetSdkMajor -ge 6) ([string]$buildPlan.toolchain.minimumDotnetSdkMajor)
        Add-Check "build-plan:script" ($buildPlan.unsignedDryRun.script -eq "tools\test-installer-toolchain.ps1") ([string]$buildPlan.unsignedDryRun.script)
        Add-Check "build-plan:source" ($buildPlan.unsignedDryRun.source -eq "installer\SamhainSecurityInstaller.wxs") ([string]$buildPlan.unsignedDryRun.source)
        Add-Check "build-plan:publish-blocked" (-not [bool]$buildPlan.unsignedDryRun.publishAllowed) ([string]$buildPlan.unsignedDryRun.publishAllowed)
        Add-Check "build-plan:install-blocked" (-not [bool]$buildPlan.unsignedDryRun.installAllowed) ([string]$buildPlan.unsignedDryRun.installAllowed)
        Add-Check "build-plan:requires-signing" ([bool]$buildPlan.unsignedDryRun.requiresProductionSigning) ([string]$buildPlan.unsignedDryRun.requiresProductionSigning)
    }
    catch {
        Add-Check "build-plan:json" $false $_.Exception.Message
    }
}

if (Test-Path -LiteralPath $wixSourcePath) {
    try {
        [xml]$wixXml = Get-Content -LiteralPath $wixSourcePath -Raw
        Add-Check "wix-source:xml" ($wixXml.DocumentElement.LocalName -eq "Wix") $wixXml.DocumentElement.LocalName
    }
    catch {
        Add-Check "wix-source:xml" $false $_.Exception.Message
    }
}

$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Add-Check "manifest:version" ($manifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($manifest.version)"
    Add-Check "manifest:installer-toolchain-script" ($manifest.quality.installerToolchainScript -eq "tools\test-installer-toolchain.ps1") ([string]$manifest.quality.installerToolchainScript)
    Add-Check "manifest:installer-toolchain-gate" ($manifest.quality.gates -contains "tools\test-installer-toolchain.ps1") "gates=$($manifest.quality.gates -join ',')"
    Add-Check "manifest:installer-toolchain-status" ($manifest.releaseReadiness.installer.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$manifest.releaseReadiness.installer.status)
    Add-Check "manifest:installer-build-plan" ($manifest.releaseReadiness.installer.buildPlan -eq "installer\installer-build-plan.json") ([string]$manifest.releaseReadiness.installer.buildPlan)
    Add-Check "manifest:installer-toolchain-preflight" ($manifest.releaseReadiness.installer.toolchainPreflight -eq "tools\test-installer-toolchain.ps1") ([string]$manifest.releaseReadiness.installer.toolchainPreflight)
    Add-Check "manifest:installer-publish-blocked" (-not [bool]$manifest.releaseReadiness.installer.publishAllowed) ([string]$manifest.releaseReadiness.installer.publishAllowed)
}

$updateManifest = $null
if (Test-Path -LiteralPath $updateManifestPath) {
    $updateManifest = Get-Content -LiteralPath $updateManifestPath -Raw | ConvertFrom-Json
    Add-Check "update-manifest:version" ($updateManifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($updateManifest.version)"
    Add-Check "update-manifest:installer-toolchain-script" ($updateManifest.verification.installerToolchainScript -eq "tools\test-installer-toolchain.ps1") ([string]$updateManifest.verification.installerToolchainScript)
    Add-Check "update-manifest:installer-toolchain-status" ($updateManifest.signedInstaller.status -eq "toolchain-preflight-unsigned-msi-dry-run") ([string]$updateManifest.signedInstaller.status)
    Add-Check "update-manifest:installer-build-plan" ($updateManifest.signedInstaller.buildPlan -eq "installer\installer-build-plan.json") ([string]$updateManifest.signedInstaller.buildPlan)
    Add-Check "update-manifest:installer-toolchain-preflight" ($updateManifest.signedInstaller.toolchainPreflight -eq "tools\test-installer-toolchain.ps1") ([string]$updateManifest.signedInstaller.toolchainPreflight)
    Add-Check "update-manifest:installer-publish-blocked" (-not [bool]$updateManifest.signedInstaller.publishAllowed) ([string]$updateManifest.signedInstaller.publishAllowed)
}

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Check "dotnet:available" ($null -ne $dotnetCommand) $(if ($dotnetCommand) { $dotnetCommand.Source } else { "missing" })
$dotnetVersion = ""
if ($dotnetCommand) {
    $dotnetVersion = ((& $dotnetCommand.Source --version 2>&1) | Out-String).Trim()
    $dotnetMajor = Compare-MajorVersion -Value $dotnetVersion
    Add-Check "dotnet:minimum-major" ($dotnetMajor -ge 6) "version=$dotnetVersion major=$dotnetMajor"
}

$resolvedWix = Resolve-WixCommand -ExplicitPath $WixExe -PackageRootValue $PackageRoot
$wixVersion = ""
$wixMajor = 0
$wixUsable = $false
if (-not [string]::IsNullOrWhiteSpace($resolvedWix)) {
    $wixVersion = ((& $resolvedWix --version 2>&1) | Out-String).Trim()
    $wixMajor = Compare-MajorVersion -Value $wixVersion
    $wixUsable = ($wixMajor -gt 0 -and $wixMajor -lt 7)
    Add-InfoCheck "wix:found" "$resolvedWix version=$wixVersion"
    if ($wixUsable) {
        Add-InfoCheck "wix:major-supported" "major=$wixMajor"
    }
    elseif ($RequireWix) {
        Add-Check "wix:major-supported" $false "major=$wixMajor; unattended gate expects WiX 6.x or earlier"
    }
    else {
        Add-InfoCheck "wix:major-supported" "unsupported-major=$wixMajor; build skipped"
        $warnings.Add("WiX was found but is not usable for unattended unsigned MSI dry-run; use WiX 6.x or pass an explicit compatible path.") | Out-Null
    }
}
else {
    Add-InfoCheck "wix:found" "missing"
    if ($RequireWix) {
        Add-Check "wix:required" $false "missing"
    }
    else {
        $warnings.Add("WiX is not installed; unsigned MSI dry-run is recorded as a plan-only preflight.") | Out-Null
    }
}

$msiBuilt = $false
$msiPath = ""
$msiHash = ""
$msiSize = 0
$signatureStatus = ""
if ($wixUsable) {
    $ownsOutputRoot = $false
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("SamhainSecurityInstallerDryRun-" + [Guid]::NewGuid().ToString("N"))
        $ownsOutputRoot = $true
    }

    $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
    if ($ownsOutputRoot) {
        Assert-UnderTemp $OutputRoot
    }

    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    $msiPath = Join-Path $OutputRoot ("SamhainSecurityInstaller-$ExpectedVersion-win-x64-unsigned.msi")
    $arguments = @(
        "build",
        $wixSourcePath,
        "-arch",
        "x64",
        "-d",
        "ProductVersion=$ExpectedVersion",
        "-d",
        "PackageRoot=$PackageRoot",
        "-out",
        $msiPath,
        "-pdbtype",
        "none"
    )

    $global:LASTEXITCODE = 0
    $buildOutput = & $resolvedWix @arguments *>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $detail = ($buildOutput | Out-String).Trim()
    if ($detail.Length -gt 900) {
        $detail = $detail.Substring(0, 900)
    }

    Add-Check "wix:build-unsigned-msi" ($exitCode -eq 0) "exit=$exitCode $detail"
    $msiBuilt = (Test-Path -LiteralPath $msiPath)
    Add-Check "unsigned-msi:exists" $msiBuilt $msiPath
    if ($msiBuilt) {
        $msi = Get-Item -LiteralPath $msiPath
        $msiSize = $msi.Length
        $msiHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $msiPath).Hash.ToLowerInvariant()
        $signature = Get-AuthenticodeSignature -LiteralPath $msiPath
        $signatureStatus = [string]$signature.Status
        Add-Check "unsigned-msi:size" ($msiSize -gt 0) "size=$msiSize"
        Add-Check "unsigned-msi:sha256" ($msiHash -match '^[a-f0-9]{64}$') $msiHash
        Add-Check "unsigned-msi:not-signed" ($signatureStatus -ne "Valid") "status=$signatureStatus"
        $warnings.Add("Unsigned MSI dry-run built locally; it is not installable for public release until production signing is applied.") | Out-Null
    }

    if ($ownsOutputRoot -and (-not $KeepOutput)) {
        Assert-UnderTemp $OutputRoot
        Remove-Item -LiteralPath $OutputRoot -Recurse -Force -ErrorAction SilentlyContinue
        Add-InfoCheck "unsigned-msi:cleanup" $OutputRoot
    }
}
else {
    Add-InfoCheck "unsigned-msi:plan-only" "build skipped until WiX 6.x toolchain is available"
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    requireWix = [bool]$RequireWix
    wixExe = $resolvedWix
    wixVersion = $wixVersion
    wixUsable = $wixUsable
    msiBuilt = $msiBuilt
    msiPath = $msiPath
    msiSizeBytes = $msiSize
    msiSha256 = $msiHash
    msiSignatureStatus = $signatureStatus
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
        Write-Host "Installer toolchain gate failed: $PackageRoot"
    }
    else {
        Write-Host "Installer toolchain gate passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

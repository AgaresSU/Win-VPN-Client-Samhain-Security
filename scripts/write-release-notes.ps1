param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [string]$OutputPath = "",
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
$versionPath = Join-Path $PackageRoot "VERSION"
$packageVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = $packageVersion
}
if ($packageVersion -ne $ExpectedVersion) {
    throw "Version mismatch. expected=$ExpectedVersion actual=$packageVersion"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$PackageRoot.release-notes.md"
}

$manifestPath = Join-Path $PackageRoot "release-manifest.json"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$cleanEvidencePath = "$PackageRoot.clean-machine-evidence.json"
$releaseEvidencePath = "$PackageRoot.release-evidence.json"
$archivePath = "$PackageRoot.zip"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$updateManifest = if (Test-Path $updateManifestPath) { Get-Content -LiteralPath $updateManifestPath -Raw | ConvertFrom-Json } else { $null }
$archiveHash = if (Test-Path $archivePath) { (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant() } else { "" }
$readinessStatus = if ($manifest.releaseReadiness) { [string]$manifest.releaseReadiness.status } else { "not declared" }
$runtimeBundleLockPath = Join-Path $PackageRoot "runtime-bundle.lock.json"
$runtimeBundleStatePath = Join-Path $PackageRoot "app\engines\runtime-bundle-state.json"

$cleanEvidenceStatus = "not generated"
if (Test-Path $cleanEvidencePath) {
    $cleanEvidence = Get-Content -LiteralPath $cleanEvidencePath -Raw | ConvertFrom-Json
    $cleanEvidenceStatus = if ($cleanEvidence.ok) { "passed" } else { "failed" }
}

$releaseEvidenceStatus = "not generated"
if (Test-Path $releaseEvidencePath) {
    $releaseEvidence = Get-Content -LiteralPath $releaseEvidencePath -Raw | ConvertFrom-Json
    $releaseEvidenceStatus = if ($releaseEvidence.ok) { "passed" } else { "failed" }
}

$lines = @(
    "# Samhain Security Native $packageVersion",
    "",
    "Channel: $($manifest.quality.channel)",
    "Runtime: $($manifest.runtime)",
    "Signing status: $($manifest.signing.status)",
    "Release readiness: $readinessStatus",
    "",
    "## What Is Included",
    "",
    "- Simple daily flow: add or paste a subscription, select a server, connect, inspect status, and disconnect.",
    "- Saved subscriptions with grouped server lists, refresh, rename, delete, pin, safe URL copy, and latency checks.",
    "- Protocol coverage through bundled-runtime contracts: VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG.",
    "- Route modes: whole computer, selected apps only through the release-supported proxy-aware path, and except-selected documented as blocked until the signed WFP layer exists.",
    "- Protection planning: kill switch, DNS guard, IPv6 policy, recovery, and emergency restore remain service-owned and identity-gated.",
    "- Diagnostics: redacted support bundle, health summary, recent errors, service self-check, runtime inventory, and audit tail.",
    "- Desktop integration: tray, startup registration, single-instance handoff, and samhain:// link ownership evidence.",
    "- Update safety: stable update manifest, archive SHA256, downgrade guard, explicit recovery override, and previous-package rollback slot.",
    "- Update rehearsal: local archive extraction, isolated previous-package snapshot, candidate apply, and rollback restore validation.",
    "- Public updater rollout boundary: production signing and signed-installer handoff are required before public publishing is allowed.",
    "- Signed installer skeleton: WiX project scaffold, signing policy, installer handoff contract, and preflight gate.",
    "- Installer toolchain preflight: WiX build plan, optional unsigned MSI dry-run, and public publishing blocked while unsigned.",
    "- Security posture: bounded IPC payloads, command validation, bundled-only runtime search by default, storage boundary checks, and redacted logs.",
    "- Runtime bundle preparation: locked runtime layout, package state file, validation script, SHA256 evidence when binaries are present, and clear missing-runtime status.",
    "- Privileged service readiness: packaged preflight script, ProgramData machine storage policy, and explicit TUN/adapter gate evidence.",
    "- Release readiness docs: stable gates, protocol matrix, visual QA, security posture, and clean-machine evidence are packaged together.",
    "",
    "## Artifacts",
    "",
    "- Package: $PackageRoot",
    "- Archive: $archivePath",
    "- Archive SHA256: $archiveHash",
    "- Update manifest: $updateManifestPath",
    "- Checksums: $(Join-Path $PackageRoot "checksums.txt")",
    "- Runtime bundle lock: $runtimeBundleLockPath",
    "- Runtime bundle state: $runtimeBundleStatePath",
    "- Generated release notes: $OutputPath",
    "",
    "## Verification",
    "",
    "- Package validation: required before release.",
    "- Update manifest verification: $([bool]$updateManifest)",
    "- Clean-machine evidence: $cleanEvidenceStatus",
    "- Release evidence: $releaseEvidenceStatus",
    "- Security posture: service.self-check plus package manifest policy.",
    "",
    "## Known Limits",
    "",
    "- Production code signing certificate is not applied yet; package remains unsigned-dev.",
    "- Signed installer publishing remains blocked until the production certificate and clean-machine rehearsal are complete.",
    "- Unsigned MSI dry-run output is local-only and must not be published or installed as a production release.",
    "- Production runtime binaries must be supplied and validated on clean Windows machines for each protocol family.",
    "- Transparent except-selected application routing remains blocked until the signed WFP layer is ready.",
    "- Machine-scope writes require an elevated installer path; current-user operation remains the fallback."
)

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$summary = [PSCustomObject]@{
    ok = $true
    version = $packageVersion
    packageRoot = $PackageRoot
    archivePath = $archivePath
    archiveSha256 = $archiveHash
    outputPath = [System.IO.Path]::GetFullPath($OutputPath)
    runtimeBundleLock = $runtimeBundleLockPath
    runtimeBundleState = $runtimeBundleStatePath
    cleanMachineEvidence = $cleanEvidenceStatus
    releaseEvidence = $releaseEvidenceStatus
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 5
}
else {
    Write-Host "Release notes: $OutputPath"
}

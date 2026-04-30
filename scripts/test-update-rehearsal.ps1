param(
    [string]$PackageRoot = "",
    [string]$ManifestPath = "",
    [string]$ArchivePath = "",
    [string]$ExpectedVersion = "",
    [string]$PreviousVersion = "",
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

function Assert-UnderTemp {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $fullPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside temp: $fullPath"
    }
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
        return $null
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
    return [PSCustomObject]@{
        exitCode = $exitCode
        output = $output
        detail = $detail
    }
}

function Get-PreviousVersion {
    param([string]$Version)

    try {
        $parsed = [version]$Version
        if ($parsed.Build -gt 0) {
            return "$($parsed.Major).$($parsed.Minor).$($parsed.Build - 1)"
        }
    }
    catch {
    }

    return "0.0.0"
}

function Copy-RehearsalPackage {
    param(
        [string]$SourceRoot,
        [string]$TargetRoot
    )

    New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null

    foreach ($entry in @("app", "service", "assets", "docs", "tools")) {
        $source = Join-Path $SourceRoot $entry
        $target = Join-Path $TargetRoot $entry
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
        }
    }

    foreach ($file in @("README.md", "VERSION", "release-manifest.json", "checksums.txt", "desktop-integration.json", "install-state.json", "engine-inventory.json", "runtime-bundle.lock.json")) {
        $source = Join-Path $SourceRoot $file
        $target = Join-Path $TargetRoot $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
}

function Set-RehearsalVersion {
    param(
        [string]$TargetRoot,
        [string]$Version
    )

    Set-Content -LiteralPath (Join-Path $TargetRoot "VERSION") -Value $Version -Encoding ASCII
    $manifestPath = Join-Path $TargetRoot "release-manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.version = $Version
        $manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    }
}

function Read-VersionFile {
    param([string]$Root)

    $path = Join-Path $Root "VERSION"
    if (-not (Test-Path -LiteralPath $path)) {
        return ""
    }

    return (Get-Content -LiteralPath $path -Raw).Trim()
}

function Save-RehearsalRollbackSnapshot {
    param(
        [string]$InstallRoot,
        [string]$SnapshotRoot,
        [string]$StatePath
    )

    $version = Read-VersionFile -Root $InstallRoot
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SnapshotRoot) | Out-Null
    if (Test-Path -LiteralPath $SnapshotRoot) {
        Remove-Item -LiteralPath $SnapshotRoot -Recurse -Force
    }
    Copy-RehearsalPackage -SourceRoot $InstallRoot -TargetRoot $SnapshotRoot

    [PSCustomObject]@{
        product = "Samhain Security"
        version = $version
        source = $InstallRoot
        snapshotRoot = $SnapshotRoot
        recoveryModeRequired = $true
        savedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Restore-RehearsalRollbackSnapshot {
    param(
        [string]$InstallRoot,
        [string]$SnapshotRoot,
        [string]$StatePath
    )

    Copy-RehearsalPackage -SourceRoot $SnapshotRoot -TargetRoot $InstallRoot
    $version = Read-VersionFile -Root $InstallRoot

    [PSCustomObject]@{
        product = "Samhain Security"
        version = $version
        source = $SnapshotRoot
        restoredTo = $InstallRoot
        recoveryModeRequired = $true
        restoredAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Invoke-IsolatedLocalOpsDryRun {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string]$Action,
        [string]$PackageRoot,
        [string]$InstallRoot,
        [string]$SandboxRoot
    )

    $oldAppData = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    try {
        $env:APPDATA = Join-Path $SandboxRoot "Roaming"
        $env:LOCALAPPDATA = Join-Path $SandboxRoot "Local"
        New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:LOCALAPPDATA | Out-Null
        Invoke-Tool -Name $Name -ScriptPath $ScriptPath -Parameters @{
            Action = $Action
            PackageRoot = $PackageRoot
            InstallRoot = $InstallRoot
            DryRun = $true
        } | Out-Null
    }
    finally {
        $env:APPDATA = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData
    }
}

$PackageRoot = Resolve-PackageRoot $PackageRoot
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $ExpectedVersion = (Get-Content -LiteralPath (Join-Path $PackageRoot "VERSION") -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($PreviousVersion)) {
    $PreviousVersion = Get-PreviousVersion -Version $ExpectedVersion
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = "$PackageRoot.update-manifest.json"
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = "$PackageRoot.zip"
}

$ManifestPath = [System.IO.Path]::GetFullPath((Resolve-Path $ManifestPath -ErrorAction Stop))
$ArchivePath = [System.IO.Path]::GetFullPath((Resolve-Path $ArchivePath -ErrorAction Stop))
$toolsRoot = Join-Path $PackageRoot "tools"
$verifyScript = Join-Path $toolsRoot "verify-update-manifest.ps1"
$validateScript = Join-Path $toolsRoot "validate-package.ps1"
$localOpsScript = Join-Path $toolsRoot "local-ops.ps1"
$checks = New-Object System.Collections.Generic.List[object]
$failed = $false
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("SamhainSecurityUpdateRehearsal-" + [Guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $tempRoot "candidate"
$installRoot = Join-Path $tempRoot "Local\SamhainSecurity"
$dataRoot = Join-Path $tempRoot "Roaming\SamhainSecurity"
$snapshotRoot = Join-Path $dataRoot "rollback\previous-package"
$rollbackStatePath = Join-Path $dataRoot "rollback\rollback-state.json"
$archiveHash = ""
$manifest = $null

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    Add-Check "manifest:version" ($manifest.version -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$($manifest.version)"
    Add-Check "manifest:rehearsal-script" ($manifest.verification.updateRehearsalScript -eq "tools\test-update-rehearsal.ps1") ([string]$manifest.verification.updateRehearsalScript)
    Add-Check "manifest:update-policy-rollback" ([bool]$manifest.updatePolicy.rollback.preservePreviousPackage) ([string]$manifest.updatePolicy.rollback.preservePreviousPackage)
    Add-Check "manifest:update-policy-explicit-recovery" ([bool]$manifest.updatePolicy.explicitRecoveryRequired) ([string]$manifest.updatePolicy.explicitRecoveryRequired)

    $archive = Get-Item -LiteralPath $ArchivePath
    $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
    Add-Check "archive:file-name" ($archive.Name -eq $manifest.package.fileName) "manifest=$($manifest.package.fileName) actual=$($archive.Name)"
    Add-Check "archive:size" ($archive.Length -eq [int64]$manifest.package.sizeBytes) "expected=$($manifest.package.sizeBytes) actual=$($archive.Length)"
    Add-Check "archive:sha256" ($archiveHash -eq ([string]$manifest.package.sha256).ToLowerInvariant()) "expected=$($manifest.package.sha256) actual=$archiveHash"

    Invoke-Tool -Name "update-manifest:local-archive" -ScriptPath $verifyScript -Parameters @{
        ManifestPath = $ManifestPath
        ArchivePath = $ArchivePath
        ExpectedVersion = $ExpectedVersion
        RequireStableChannel = $true
        Json = $true
    } | Out-Null

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractRoot -Force
    Add-Check "extract:version-file" (Test-Path -LiteralPath (Join-Path $extractRoot "VERSION")) (Join-Path $extractRoot "VERSION")
    Add-Check "extract:release-manifest" (Test-Path -LiteralPath (Join-Path $extractRoot "release-manifest.json")) (Join-Path $extractRoot "release-manifest.json")
    Add-Check "extract:version" ((Read-VersionFile -Root $extractRoot) -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$(Read-VersionFile -Root $extractRoot)"

    Invoke-Tool -Name "extract:validate-package" -ScriptPath (Join-Path $extractRoot "tools\validate-package.ps1") -Parameters @{
        PackageRoot = $extractRoot
        ExpectedVersion = $ExpectedVersion
        RunServiceStatus = $true
        Json = $true
    } | Out-Null

    Invoke-IsolatedLocalOpsDryRun -Name "local-ops:install-plan" -ScriptPath $localOpsScript -Action "Install" -PackageRoot $extractRoot -InstallRoot $installRoot -SandboxRoot $tempRoot
    Invoke-IsolatedLocalOpsDryRun -Name "local-ops:repair-plan" -ScriptPath $localOpsScript -Action "Repair" -PackageRoot $extractRoot -InstallRoot $installRoot -SandboxRoot $tempRoot
    Invoke-IsolatedLocalOpsDryRun -Name "local-ops:rollback-plan" -ScriptPath $localOpsScript -Action "Rollback" -PackageRoot $extractRoot -InstallRoot $installRoot -SandboxRoot $tempRoot

    Copy-RehearsalPackage -SourceRoot $extractRoot -TargetRoot $installRoot
    Set-RehearsalVersion -TargetRoot $installRoot -Version $PreviousVersion
    Add-Check "previous-install:version" ((Read-VersionFile -Root $installRoot) -eq $PreviousVersion) "expected=$PreviousVersion actual=$(Read-VersionFile -Root $installRoot)"

    Save-RehearsalRollbackSnapshot -InstallRoot $installRoot -SnapshotRoot $snapshotRoot -StatePath $rollbackStatePath
    Add-Check "rollback:snapshot-version" ((Read-VersionFile -Root $snapshotRoot) -eq $PreviousVersion) "expected=$PreviousVersion actual=$(Read-VersionFile -Root $snapshotRoot)"
    Add-Check "rollback:state-saved" (Test-Path -LiteralPath $rollbackStatePath) $rollbackStatePath

    Copy-RehearsalPackage -SourceRoot $extractRoot -TargetRoot $installRoot
    Add-Check "apply:candidate-version" ((Read-VersionFile -Root $installRoot) -eq $ExpectedVersion) "expected=$ExpectedVersion actual=$(Read-VersionFile -Root $installRoot)"

    Restore-RehearsalRollbackSnapshot -InstallRoot $installRoot -SnapshotRoot $snapshotRoot -StatePath $rollbackStatePath
    Add-Check "rollback:restored-version" ((Read-VersionFile -Root $installRoot) -eq $PreviousVersion) "expected=$PreviousVersion actual=$(Read-VersionFile -Root $installRoot)"

    $rollbackState = Get-Content -LiteralPath $rollbackStatePath -Raw | ConvertFrom-Json
    Add-Check "rollback:state-restored" ($rollbackState.version -eq $PreviousVersion) "state=$($rollbackState.version)"
    Add-Check "rollback:explicit-recovery" ([bool]$rollbackState.recoveryModeRequired) ([string]$rollbackState.recoveryModeRequired)
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Assert-UnderTemp $tempRoot
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    manifestPath = $ManifestPath
    archivePath = $ArchivePath
    version = $ExpectedVersion
    previousVersion = $PreviousVersion
    archiveSha256 = $archiveHash
    checks = $checks
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 7
}
else {
    $checks | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Update rehearsal failed: $ArchivePath"
    }
    else {
        Write-Host "Update rehearsal passed: $ArchivePath"
    }
}

if ($failed) {
    exit 1
}

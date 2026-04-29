param(
    [string]$ManifestPath = "",
    [string]$ArchivePath = "",
    [string]$ExpectedVersion = "",
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
Add-Check "manifest:algorithm" ($manifest.package.algorithm -eq "SHA256") ([string]$manifest.package.algorithm)

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

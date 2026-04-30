param(
    [string]$BundleRoot = "",
    [string]$PackageRoot = "",
    [string]$LockPath = "",
    [string]$CacheRoot = "",
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-DefaultContext {
    $scriptDir = Split-Path -Parent $PSCommandPath
    if ((Split-Path -Leaf $scriptDir) -eq "tools") {
        return [PSCustomObject]@{
            kind = "package"
            root = Resolve-FullPath (Join-Path $scriptDir "..")
        }
    }

    return [PSCustomObject]@{
        kind = "repo"
        root = Resolve-FullPath (Join-Path $scriptDir "..")
    }
}

function Assert-UnderBase {
    param(
        [string]$Path,
        [string]$Base
    )

    $fullPath = Resolve-FullPath $Path
    $basePath = Resolve-FullPath $Base
    if (-not $fullPath.StartsWith($basePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside expected root: $fullPath"
    }
}

function Normalize-RelativePath {
    param([string]$Value)

    return ([string]$Value).Replace("/", "\").TrimStart("\")
}

function Add-Step {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    if (-not $Ok) {
        $script:failed = $true
    }

    $script:steps.Add([PSCustomObject]@{
        name = $Name
        ok = $Ok
        detail = $Detail
    }) | Out-Null
}

function Resolve-DownloadUrl {
    param([object]$Runtime)

    $runtimeId = [string]$Runtime.runtimeId
    $source = $Runtime.source
    $downloadUrl = [string]$source.downloadUrl
    if (-not [string]::IsNullOrWhiteSpace($downloadUrl)) {
        return $downloadUrl
    }

    $ownerCodePoints = @($source.githubOwnerCodePoints)
    $repository = [string]$source.githubRepository
    $releaseTag = [string]$source.githubReleaseTag
    $archiveName = [string]$source.archiveName
    if ($ownerCodePoints.Count -eq 0 -or
        [string]::IsNullOrWhiteSpace($repository) -or
        [string]::IsNullOrWhiteSpace($releaseTag) -or
        [string]::IsNullOrWhiteSpace($archiveName)) {
        throw "Runtime $runtimeId has no download source in runtime-bundle.lock.json"
    }

    $owner = -join ($ownerCodePoints | ForEach-Object { [char][int]$_ })
    return "https://github.com/$owner/$repository/releases/download/$releaseTag/$archiveName"
}

function Get-ArchivePath {
    param(
        [object]$Runtime,
        [string]$CacheRoot
    )

    $archiveName = [string]$Runtime.source.archiveName
    if ([string]::IsNullOrWhiteSpace($archiveName)) {
        $archiveName = Split-Path -Leaf (Resolve-DownloadUrl -Runtime $Runtime)
    }
    return Join-Path $CacheRoot $archiveName
}

function Download-VerifiedArchive {
    param(
        [object]$Runtime,
        [string]$CacheRoot,
        [switch]$Force
    )

    $runtimeId = [string]$Runtime.runtimeId
    $downloadUrl = Resolve-DownloadUrl -Runtime $Runtime
    $expectedSha256 = ([string]$Runtime.source.archiveSha256).ToLowerInvariant()
    $expectedSize = [int64]$Runtime.source.archiveSizeBytes

    if ($expectedSha256 -notmatch '^[a-f0-9]{64}$') {
        throw "Runtime $runtimeId has no locked archive SHA256"
    }

    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $archivePath = Get-ArchivePath -Runtime $Runtime -CacheRoot $CacheRoot

    if ($Force -or -not (Test-Path -LiteralPath $archivePath)) {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
    }

    $file = Get-Item -LiteralPath $archivePath
    if ($expectedSize -gt 0 -and $file.Length -ne $expectedSize) {
        throw "Runtime $runtimeId archive size mismatch. expected=$expectedSize actual=$($file.Length)"
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "Runtime $runtimeId archive hash mismatch. expected=$expectedSha256 actual=$actualSha256"
    }

    [PSCustomObject]@{
        path = $archivePath
        sha256 = $actualSha256
        sizeBytes = $file.Length
    }
}

function Expand-RuntimeArchive {
    param(
        [object]$Runtime,
        [string]$ArchivePath,
        [string]$ExtractRoot
    )

    $kind = ([string]$Runtime.source.archiveKind).ToLowerInvariant()
    New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null

    if ($kind -eq "zip") {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force
        return
    }

    if ($kind -eq "msi") {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/a", $ArchivePath, "/qn", "TARGETDIR=$ExtractRoot") -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0) {
            throw "msiexec extraction failed for $ArchivePath with exit code $($process.ExitCode)"
        }
        return
    }

    throw "Unsupported archive kind: $kind"
}

function Resolve-ExtractedFile {
    param(
        [string]$ExtractRoot,
        [string]$RelativePath
    )

    $relative = Normalize-RelativePath $RelativePath
    $candidate = Join-Path $ExtractRoot $relative
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $leaf = Split-Path -Leaf $relative
    $fallback = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    throw "Extracted file not found: $relative"
}

$context = Resolve-DefaultContext
if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    $context = [PSCustomObject]@{
        kind = "package"
        root = Resolve-FullPath $PackageRoot
    }
}

if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $LockPath = Join-Path $context.root "runtime-bundle.lock.json"
}
if ([string]::IsNullOrWhiteSpace($BundleRoot)) {
    if ($context.kind -eq "package") {
        $BundleRoot = Join-Path $context.root "app\engines"
    }
    else {
        $BundleRoot = Join-Path $context.root "engines"
    }
}
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
    $CacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) "SamhainSecurityRuntimeArchives"
}

$LockPath = Resolve-FullPath (Resolve-Path $LockPath -ErrorAction Stop)
$BundleRoot = Resolve-FullPath $BundleRoot
$CacheRoot = Resolve-FullPath $CacheRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("SamhainSecurityRuntimeExtract-" + [Guid]::NewGuid().ToString("N"))
$steps = New-Object System.Collections.Generic.List[object]
$runtimeResults = New-Object System.Collections.Generic.List[object]
$failed = $false

Assert-UnderBase -Path $BundleRoot -Base $context.root
New-Item -ItemType Directory -Force -Path $BundleRoot | Out-Null

try {
    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    Add-Step "lock:schema" ($lock.schema -eq "samhain.runtimeBundleLock") ([string]$lock.schema)
    Add-Step "lock:version" (-not [string]::IsNullOrWhiteSpace([string]$lock.version)) ([string]$lock.version)

    foreach ($runtime in @($lock.runtimes)) {
        $runtimeId = [string]$runtime.runtimeId
        $runtimeDir = Join-Path $BundleRoot (Normalize-RelativePath ([string]$runtime.bundle.directory))
        Assert-UnderBase -Path $runtimeDir -Base $BundleRoot
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

        $archive = Download-VerifiedArchive -Runtime $runtime -CacheRoot $CacheRoot -Force:$Force
        Add-Step "runtime:$runtimeId:archive" $true "sha256=$($archive.sha256) size=$($archive.sizeBytes)"

        $extractRoot = Join-Path $tempRoot $runtimeId
        Expand-RuntimeArchive -Runtime $runtime -ArchivePath $archive.path -ExtractRoot $extractRoot

        $copiedFiles = New-Object System.Collections.Generic.List[object]
        foreach ($file in @($runtime.source.extractFiles)) {
            $sourceFile = Resolve-ExtractedFile -ExtractRoot $extractRoot -RelativePath ([string]$file.source)
            $targetName = Split-Path -Leaf ([string]$file.target)
            $targetFile = Join-Path $runtimeDir $targetName
            Assert-UnderBase -Path $targetFile -Base $runtimeDir
            Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
            $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetFile).Hash.ToLowerInvariant()
            $copiedFiles.Add([PSCustomObject]@{
                file = $targetName
                sha256 = $targetHash
                sizeBytes = (Get-Item -LiteralPath $targetFile).Length
            }) | Out-Null
        }

        $primaryPath = Join-Path $runtimeDir ([string]$runtime.bundle.executable)
        Add-Step "runtime:$runtimeId:primary" (Test-Path -LiteralPath $primaryPath) $primaryPath
        $runtimeResults.Add([PSCustomObject]@{
            runtimeId = $runtimeId
            pinnedVersion = [string]$runtime.source.pinnedVersion
            archive = [PSCustomObject]@{
                url = Resolve-DownloadUrl -Runtime $runtime
                path = $archive.path
                sha256 = $archive.sha256
                sizeBytes = $archive.sizeBytes
            }
            outputDirectory = $runtimeDir
            files = $copiedFiles
        }) | Out-Null
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Assert-UnderBase -Path $tempRoot -Base ([System.IO.Path]::GetTempPath())
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

$prepareScript = Join-Path (Split-Path -Parent $PSCommandPath) "prepare-runtime-bundle.ps1"
if (Test-Path -LiteralPath $prepareScript) {
    $global:LASTEXITCODE = 0
    $prepareOutput = & $prepareScript -BundleRoot $BundleRoot -LockPath $LockPath -Json 2>&1
    $prepareExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Add-Step "runtime-bundle:prepare-state" ($prepareExit -eq 0) "exit=$prepareExit"
    if ($prepareExit -ne 0) {
        $failed = $true
    }
}
else {
    Add-Step "runtime-bundle:prepare-state" $false "missing=$prepareScript"
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    product = "Samhain Security Native"
    version = [string]$lock.version
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    context = $context.kind
    lockPath = $LockPath
    bundleRoot = $BundleRoot
    cacheRoot = $CacheRoot
    runtimes = $runtimeResults
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 8
}
else {
    $runtimeResults | Select-Object runtimeId, pinnedVersion, outputDirectory | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Runtime bundle fetch failed: $BundleRoot"
    }
    else {
        Write-Host "Runtime bundle fetched: $BundleRoot"
    }
}

if ($failed) {
    exit 1
}

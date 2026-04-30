param(
    [string]$BundleRoot = "",
    [string]$PackageRoot = "",
    [string]$LockPath = "",
    [switch]$ValidateOnly,
    [switch]$RequireAvailable,
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

function Get-VersionProbe {
    param(
        [string]$ExecutablePath,
        [object[]]$Arguments
    )

    $version = ""
    $status = "not-probed"

    try {
        $output = & $ExecutablePath @Arguments 2>&1
        if ($LASTEXITCODE -eq 0) {
            $status = "ok"
        }
        else {
            $status = "exit-$LASTEXITCODE"
        }

        $line = (($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1) -as [string])
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $version = $line.Trim()
            if ($version.Length -gt 160) {
                $version = $version.Substring(0, 160)
            }
        }
    }
    catch {
        $status = "probe-error"
        $version = $_.Exception.Message
        if ($version.Length -gt 160) {
            $version = $version.Substring(0, 160)
        }
    }

    [PSCustomObject]@{
        status = $status
        version = $version
    }
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

$LockPath = Resolve-FullPath (Resolve-Path $LockPath -ErrorAction Stop)
$BundleRoot = Resolve-FullPath $BundleRoot
$checks = New-Object System.Collections.Generic.List[object]
$runtimeStates = New-Object System.Collections.Generic.List[object]
$failed = $false

if (-not $ValidateOnly) {
    Assert-UnderBase -Path $BundleRoot -Base $context.root
    New-Item -ItemType Directory -Force -Path $BundleRoot | Out-Null
}

$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
Add-Check "lock:schema" ($lock.schema -eq "samhain.runtimeBundleLock") ([string]$lock.schema)
Add-Check "lock:schema-version" ([int]$lock.schemaVersion -eq 1) ([string]$lock.schemaVersion)
Add-Check "lock:product" ($lock.product -eq "Samhain Security Native") ([string]$lock.product)
Add-Check "lock:version" (-not [string]::IsNullOrWhiteSpace([string]$lock.version)) ([string]$lock.version)
Add-Check "lock:runtimes" (@($lock.runtimes).Count -ge 4) "count=$(@($lock.runtimes).Count)"

$seenRuntimeIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($runtime in @($lock.runtimes)) {
    $runtimeId = [string]$runtime.runtimeId
    $directory = Normalize-RelativePath ([string]$runtime.bundle.directory)
    $executable = Split-Path -Leaf ([string]$runtime.bundle.executable)
    $versionArgs = @($runtime.bundle.versionArgs | ForEach-Object { [string]$_ })
    $protocols = @($runtime.protocols | ForEach-Object { [string]$_ })
    $expectedPackagePath = "app\engines\$directory\$executable"
    $packagePath = Normalize-RelativePath ([string]$runtime.bundle.packagePath)
    if ([string]::IsNullOrWhiteSpace($packagePath)) {
        $packagePath = $expectedPackagePath
    }

    $runtimePrefix = "runtime:$runtimeId"
    Add-Check "${runtimePrefix}:id" ($runtimeId -match '^[a-z0-9][a-z0-9-]*$') $runtimeId
    Add-Check "${runtimePrefix}:unique" ($seenRuntimeIds.Add($runtimeId)) $runtimeId
    Add-Check "${runtimePrefix}:directory" (($directory -ne "") -and ($directory -notmatch '(^|\\)\.\.(\\|$)')) $directory
    Add-Check "${runtimePrefix}:executable" ($executable -match '\.exe$') $executable
    Add-Check "${runtimePrefix}:package-path" ($packagePath -eq $expectedPackagePath) "expected=$expectedPackagePath actual=$packagePath"
    Add-Check "${runtimePrefix}:protocols" ($protocols.Count -gt 0) "count=$($protocols.Count)"
    Add-Check "${runtimePrefix}:version-args" ($versionArgs.Count -gt 0) "count=$($versionArgs.Count)"

    $runtimeDir = Join-Path $BundleRoot $directory
    $executablePath = Join-Path $runtimeDir $executable
    Assert-UnderBase -Path $runtimeDir -Base $BundleRoot
    Assert-UnderBase -Path $executablePath -Base $BundleRoot

    if (-not $ValidateOnly) {
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
        $keepPath = Join-Path $runtimeDir ".gitkeep"
        if (-not (Test-Path -LiteralPath $keepPath)) {
            "tracked runtime directory placeholder" | Set-Content -LiteralPath $keepPath -Encoding ASCII
        }
    }

    $available = Test-Path -LiteralPath $executablePath
    $sha256 = ""
    $size = 0
    $version = ""
    $versionStatus = "missing"
    if ($available) {
        $file = Get-Item -LiteralPath $executablePath
        $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $executablePath).Hash.ToLowerInvariant()
        $size = $file.Length
        $probe = Get-VersionProbe -ExecutablePath $executablePath -Arguments $versionArgs
        $versionStatus = $probe.status
        $version = $probe.version
        Add-Check "${runtimePrefix}:sha256" ($sha256 -match '^[a-f0-9]{64}$') $sha256
        Add-Check "${runtimePrefix}:size" ($size -gt 0) "size=$size"
    }
    elseif ($RequireAvailable) {
        Add-Check "${runtimePrefix}:available" $false "missing=$executablePath"
    }

    $runtimeStates.Add([PSCustomObject]@{
        runtimeId = $runtimeId
        name = [string]$runtime.name
        kind = [string]$runtime.kind
        productionRequired = [bool]$runtime.productionRequired
        protocols = $protocols
        packagePath = $packagePath
        localPath = $executablePath
        available = $available
        status = if ($available) { "available" } else { "missing" }
        sha256 = $sha256
        fileSizeBytes = $size
        version = $version
        versionStatus = $versionStatus
        sourceProject = [string]$runtime.source.project
        sourceUrl = [string]$runtime.source.projectUrl
        pinnedVersion = [string]$runtime.source.pinnedVersion
        archiveName = [string]$runtime.source.archiveName
        archiveSha256 = [string]$runtime.source.archiveSha256
    }) | Out-Null
}

$statePath = Join-Path $BundleRoot "runtime-bundle-state.json"
$summary = [PSCustomObject]@{
    ok = -not $failed
    product = "Samhain Security Native"
    version = [string]$lock.version
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    mode = if ($ValidateOnly) { "validate" } else { "prepare" }
    context = $context.kind
    lockPath = $LockPath
    bundleRoot = $BundleRoot
    statePath = $statePath
    requireAvailable = [bool]$RequireAvailable
    runtimes = $runtimeStates
    checks = $checks
}

if (-not $ValidateOnly) {
    Assert-UnderBase -Path $statePath -Base $BundleRoot
    $summary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 7
}
else {
    $runtimeStates | Select-Object runtimeId, status, packagePath, versionStatus | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Runtime bundle validation failed: $BundleRoot"
    }
    elseif ($ValidateOnly) {
        Write-Host "Runtime bundle validation passed: $BundleRoot"
    }
    else {
        Write-Host "Runtime bundle prepared: $BundleRoot"
        Write-Host "Runtime bundle state: $statePath"
    }
}

if ($failed) {
    exit 1
}

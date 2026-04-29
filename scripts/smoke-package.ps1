param(
    [string]$PackageRoot = "",
    [string]$ExpectedVersion = "",
    [switch]$SkipLaunch,
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

$steps = New-Object System.Collections.Generic.List[object]
$failed = $false

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

function Invoke-ScriptStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Parameters
    )

    if (-not (Test-Path $ScriptPath)) {
        Add-Step $Name $false "missing=$ScriptPath"
        return
    }

    $output = & $ScriptPath @Parameters *>&1
    $exitCode = $LASTEXITCODE
    $detail = ($output | Out-String).Trim()
    if ($detail.Length -gt 500) {
        $detail = $detail.Substring(0, 500)
    }
    Add-Step $Name ($exitCode -eq 0) "exit=$exitCode $detail"
}

$toolsRoot = Join-Path $PackageRoot "tools"
$validateScript = Join-Path $toolsRoot "validate-package.ps1"
$updateVerifierScript = Join-Path $toolsRoot "verify-update-manifest.ps1"
$localOpsScript = Join-Path $toolsRoot "local-ops.ps1"
$serviceExe = Join-Path $PackageRoot "service\samhain-service.exe"
$appExe = Join-Path $PackageRoot "app\SamhainSecurityNative.exe"
$updateManifestPath = "$PackageRoot.update-manifest.json"
$archivePath = "$PackageRoot.zip"

Invoke-ScriptStep -Name "validate-package" -ScriptPath $validateScript -Parameters @{
    PackageRoot = $PackageRoot
    ExpectedVersion = $ExpectedVersion
    RunServiceStatus = $true
    Json = $true
}
Invoke-ScriptStep -Name "update-manifest" -ScriptPath $updateVerifierScript -Parameters @{
    ManifestPath = $updateManifestPath
    ArchivePath = $archivePath
    ExpectedVersion = $ExpectedVersion
    Json = $true
}
Invoke-ScriptStep -Name "local-ops:status" -ScriptPath $localOpsScript -Parameters @{
    Action = "Status"
}
Invoke-ScriptStep -Name "local-ops:install-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Install"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:repair-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Repair"
    DryRun = $true
}
Invoke-ScriptStep -Name "local-ops:uninstall-dry-run" -ScriptPath $localOpsScript -Parameters @{
    Action = "Uninstall"
    DryRun = $true
}

if (-not (Test-Path $serviceExe)) {
    Add-Step "service:status" $false "missing=$serviceExe"
}
else {
    $serviceOutput = & $serviceExe status 2>&1
    $serviceExitCode = $LASTEXITCODE
    try {
        $serviceState = ($serviceOutput | Out-String).Trim() | ConvertFrom-Json
        Add-Step "service:status" (($serviceExitCode -eq 0) -and ($serviceState.version -eq $ExpectedVersion)) "exit=$serviceExitCode version=$($serviceState.version)"
    }
    catch {
        Add-Step "service:status" $false $_.Exception.Message
    }
}

if (-not $SkipLaunch) {
    $process = $null
    try {
        if (-not (Test-Path $appExe)) {
            Add-Step "desktop:launch" $false "missing=$appExe"
        }
        else {
            $process = Start-Process -FilePath $appExe -ArgumentList "--background" -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 4
            $alive = $false
            try {
                $alive = -not $process.HasExited
            }
            catch {
                $alive = $false
            }

            if ($alive) {
                Add-Step "desktop:launch" $true "pid=$($process.Id)"
            }
            else {
                Add-Step "desktop:launch" $false "exit=$($process.ExitCode)"
            }
        }
    }
    catch {
        Add-Step "desktop:launch" $false $_.Exception.Message
    }
    finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
            }
        }

        Get-Process -Name SamhainSecurityNative -ErrorAction SilentlyContinue | ForEach-Object {
            $path = $_.Path
            if ($path -and [System.IO.Path]::GetFullPath($path).StartsWith($PackageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$summary = [PSCustomObject]@{
    ok = -not $failed
    packageRoot = $PackageRoot
    expectedVersion = $ExpectedVersion
    steps = $steps
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
}
else {
    $steps | Format-Table -AutoSize
    if ($failed) {
        Write-Host "Package smoke failed: $PackageRoot"
    }
    else {
        Write-Host "Package smoke passed: $PackageRoot"
    }
}

if ($failed) {
    exit 1
}

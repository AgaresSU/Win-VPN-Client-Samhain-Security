param(
    [string]$Version = "1.3.5",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$QtRoot = "C:\Qt\6.10.3\mingw_64"
$MingwRoot = "C:\Qt\Tools\mingw1310_64"
$PythonScripts = Join-Path $env:APPDATA "Python\Python313\Scripts"
$PackageRoot = Join-Path $RepoRoot "dist\SamhainSecurityNative-$Version-win-x64"
$ArchivePath = "$PackageRoot.zip"
$UpdateManifestPath = "$PackageRoot.update-manifest.json"
$AppOut = Join-Path $PackageRoot "app"
$ServiceOut = Join-Path $PackageRoot "service"
$DocsOut = Join-Path $PackageRoot "docs"
$ToolsOut = Join-Path $PackageRoot "tools"
$EnginesOut = Join-Path $AppOut "engines"
$QtExe = Join-Path $RepoRoot "build\desktop-qt\SamhainSecurityNative.exe"
$ServiceExe = Join-Path $RepoRoot "target\release\samhain-service.exe"

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

$EngineContracts = @(
    [PSCustomObject]@{
        runtimeId = "sing-box"
        name = "sing-box"
        kind = "sing-box"
        bundledPath = "app\engines\sing-box\sing-box.exe"
        protocols = @("vless-tcp-reality", "trojan", "shadowsocks", "hysteria2", "tuic", "sing-box")
        versionArgs = @("version")
    },
    [PSCustomObject]@{
        runtimeId = "xray"
        name = "Xray"
        kind = "xray"
        bundledPath = "app\engines\xray\xray.exe"
        protocols = @("vless-tcp-reality", "trojan")
        versionArgs = @("version")
    },
    [PSCustomObject]@{
        runtimeId = "wireguard"
        name = "WireGuard"
        kind = "wire-guard"
        bundledPath = "app\engines\wireguard\wireguard.exe"
        protocols = @("wireguard")
        versionArgs = @("--version")
    },
    [PSCustomObject]@{
        runtimeId = "amneziawg"
        name = "AmneziaWG"
        kind = "amnezia-wg"
        bundledPath = "app\engines\amneziawg\awg-quick.exe"
        protocols = @("amneziawg")
        versionArgs = @("--version")
    }
)

function New-EngineInventory {
    param([string]$Root)

    foreach ($contract in $EngineContracts) {
        $path = Join-Path $Root $contract.bundledPath
        $exists = Test-Path -LiteralPath $path
        $hash = $null
        $size = $null
        $version = $null
        $versionStatus = "missing"

        if ($exists) {
            $file = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
            $size = $file.Length
            $versionStatus = "not-probed"
            try {
                $probeOutput = & $path @($contract.versionArgs) 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $versionStatus = "ok"
                }
                else {
                    $versionStatus = "exit-$LASTEXITCODE"
                }
                $version = (($probeOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -as [string])
                if ($version -and $version.Length -gt 160) {
                    $version = $version.Substring(0, 160)
                }
            }
            catch {
                $versionStatus = "probe-error"
            }
        }

        [PSCustomObject]@{
            runtimeId = $contract.runtimeId
            kind = $contract.kind
            name = $contract.name
            bundledPath = $contract.bundledPath
            executablePath = if ($exists) { $path } else { $null }
            expectedPaths = @($contract.bundledPath)
            available = $exists
            status = if ($exists) { "available" } else { "missing" }
            protocols = $contract.protocols
            sha256 = $hash
            fileSizeBytes = $size
            version = $version
            versionStatus = $versionStatus
            message = if ($exists) { "$($contract.name) runtime available in package inventory." } else { "$($contract.name) runtime missing from $($contract.bundledPath)." }
        }
    }
}

function Assert-UnderRepo {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $repoPath = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not $fullPath.StartsWith($repoPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside project: $fullPath"
    }
}

Assert-UnderRepo $PackageRoot

& (Join-Path $PSScriptRoot "build.ps1") -Configuration $Configuration

$env:Path = "$QtRoot\bin;$MingwRoot\bin;$PythonScripts;$env:Path"

if (Test-Path $PackageRoot) {
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $AppOut, $ServiceOut, $DocsOut, $ToolsOut, $EnginesOut | Out-Null
Copy-Item -LiteralPath $QtExe -Destination $AppOut -Force
Copy-Item -LiteralPath $ServiceExe -Destination $ServiceOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "README.md") -Destination $PackageRoot -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "VERSION") -Destination $PackageRoot -Force
Copy-Item -Path (Join-Path $RepoRoot "docs\*") -Destination $DocsOut -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\local-ops.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\validate-package.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\smoke-package.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\verify-update-manifest.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\write-release-evidence.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\test-signing-readiness.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts\write-clean-machine-evidence.ps1") -Destination $ToolsOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "assets") -Destination $PackageRoot -Recurse -Force
if (Test-Path (Join-Path $RepoRoot "engines")) {
    Copy-Item -Path (Join-Path $RepoRoot "engines\*") -Destination $EnginesOut -Recurse -Force
}

$engineInventory = @(New-EngineInventory -Root $PackageRoot)
$engineInventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PackageRoot "engine-inventory.json") -Encoding UTF8

Invoke-Checked "windeployqt" @(
    "--qmldir",
    (Join-Path $RepoRoot "apps\desktop-qt\qml"),
    (Join-Path $AppOut "SamhainSecurityNative.exe")
)

$manifest = [PSCustomObject]@{
    product = "Samhain Security Native"
    version = $Version
    runtime = "win-x64"
    ui = "Qt 6 / QML"
    core = "Rust"
    operations = [PSCustomObject]@{
        scope = "CurrentUser"
        script = "tools\local-ops.ps1"
        actions = @("Install", "Repair", "Uninstall", "Status")
        privilegedService = [PSCustomObject]@{
            scope = "Machine"
            status = "installer-owned"
            script = "tools\local-ops.ps1"
            serviceName = "SamhainSecurityService"
            serviceDisplayName = "Samhain Security Service"
            actions = @("Install", "Repair", "Uninstall", "Status")
            dryRunRequired = $false
            requiresElevation = $true
        }
        serviceSelfCheck = [PSCustomObject]@{
            command = "service\samhain-service.exe self-check"
            recoveryOwner = "service"
            audit = "redacted-rotated"
        }
        desktopIntegration = [PSCustomObject]@{
            owner = "local-ops"
            statusFile = "desktop-integration.json"
            autostart = "HKCU Run"
            linkHandler = "HKCU Software Classes samhain"
            trayOwner = "desktop"
            singleInstanceHandoff = $true
        }
        enforcementTransaction = [PSCustomObject]@{
            owner = "service"
            model = "typed-apply-rollback"
            scope = @("DNSGuard", "IPv6Policy", "KillSwitchPlan", "EmergencyRestore")
            transactionIds = $true
            beforeAfterSnapshots = $true
        }
        runtimeContract = [PSCustomObject]@{
            inventory = "engine-inventory.json"
            availabilitySource = "package-inventory"
            layout = @($EngineContracts | ForEach-Object {
                [PSCustomObject]@{
                    runtimeId = $_.runtimeId
                    bundledPath = $_.bundledPath
                    protocols = $_.protocols
                }
            })
        }
    }
    signing = [PSCustomObject]@{
        status = "unsigned-dev"
        expectedPublisher = "Samhain Security"
        digestAlgorithm = "SHA256"
    }
    quality = [PSCustomObject]@{
        channel = "stable"
        validationScript = "tools\validate-package.ps1"
        smokeScript = "tools\smoke-package.ps1"
        updateManifestVerifier = "tools\verify-update-manifest.ps1"
        releaseEvidenceScript = "tools\write-release-evidence.ps1"
        signingReadinessScript = "tools\test-signing-readiness.ps1"
        cleanMachineEvidenceScript = "tools\write-clean-machine-evidence.ps1"
        serviceSelfCheckCommand = "service\samhain-service.exe self-check"
        enforcementTransactionEvidence = "service.protection_policy.transaction"
        engineInventory = "engine-inventory.json"
        runtimeHealthEvidence = "service.runtime_health"
        subscriptionOperationsEvidence = "service.subscription_operations"
        gates = @(
            "cargo test --workspace",
            "scripts\build.ps1",
            "scripts\package.ps1",
            "tools\validate-package.ps1",
            "tools\smoke-package.ps1",
            "tools\verify-update-manifest.ps1",
            "tools\write-release-evidence.ps1",
            "tools\test-signing-readiness.ps1",
            "tools\write-clean-machine-evidence.ps1"
        )
    }
    updates = [PSCustomObject]@{
        manifestFile = "SamhainSecurityNative-$Version-win-x64.update-manifest.json"
        archiveFile = "SamhainSecurityNative-$Version-win-x64.zip"
        verifier = "tools\verify-update-manifest.ps1"
    }
    createdAtUtc = (Get-Date).ToUniversalTime().ToString("O")
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PackageRoot "release-manifest.json") -Encoding UTF8

$checksumTargets = @(
    "app\SamhainSecurityNative.exe",
    "service\samhain-service.exe",
    "tools\local-ops.ps1",
    "tools\validate-package.ps1",
    "tools\smoke-package.ps1",
    "tools\verify-update-manifest.ps1",
    "tools\write-release-evidence.ps1",
    "tools\test-signing-readiness.ps1",
    "tools\write-clean-machine-evidence.ps1",
    "release-manifest.json",
    "engine-inventory.json",
    "README.md",
    "VERSION"
)

$checksums = foreach ($relative in $checksumTargets) {
    $path = Join-Path $PackageRoot $relative
    if (Test-Path $path) {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $path
        "{0}  {1}" -f $hash.Hash.ToLowerInvariant(), $relative
    }
}
$checksums | Set-Content -LiteralPath (Join-Path $PackageRoot "checksums.txt") -Encoding ASCII

Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ArchivePath -Force

$archive = Get-Item -LiteralPath $ArchivePath
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
$updateManifest = [PSCustomObject]@{
    product = "Samhain Security Native"
    version = $Version
    channel = "stable"
    runtime = "win-x64"
    package = [PSCustomObject]@{
        fileName = Split-Path -Leaf $ArchivePath
        sizeBytes = $archive.Length
        sha256 = $archiveHash
        algorithm = "SHA256"
    }
    install = [PSCustomObject]@{
        scope = "CurrentUser"
        script = "tools\local-ops.ps1"
        privilegedService = [PSCustomObject]@{
            scope = "Machine"
            status = "installer-owned"
            serviceName = "SamhainSecurityService"
            dryRunRequired = $false
            requiresElevation = $true
        }
        enforcementTransaction = [PSCustomObject]@{
            owner = "service"
            model = "typed-apply-rollback"
            beforeAfterSnapshots = $true
        }
        runtimeContract = [PSCustomObject]@{
            inventory = "engine-inventory.json"
            availabilitySource = "package-inventory"
        }
    }
    verification = [PSCustomObject]@{
        packageValidationScript = "tools\validate-package.ps1"
        smokeScript = "tools\smoke-package.ps1"
        updateManifestVerifier = "tools\verify-update-manifest.ps1"
        releaseEvidenceScript = "tools\write-release-evidence.ps1"
        signingReadinessScript = "tools\test-signing-readiness.ps1"
        cleanMachineEvidenceScript = "tools\write-clean-machine-evidence.ps1"
        serviceSelfCheckCommand = "service\samhain-service.exe self-check"
        enforcementTransactionEvidence = "service.protection_policy.transaction"
        engineInventory = "engine-inventory.json"
        runtimeHealthEvidence = "service.runtime_health"
        subscriptionOperationsEvidence = "service.subscription_operations"
        signingStatus = "unsigned-dev"
        expectedPublisher = "Samhain Security"
    }
    createdAtUtc = (Get-Date).ToUniversalTime().ToString("O")
}
$updateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $UpdateManifestPath -Encoding UTF8

Write-Host "Package: $PackageRoot"
Write-Host "Archive: $ArchivePath"
Write-Host "Update manifest: $UpdateManifestPath"

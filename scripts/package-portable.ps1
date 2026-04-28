param(
    [string]$Version = "0.5.3",
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release",
    [bool]$SelfContained = $false,
    [string]$OutputRoot = "dist"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputRootPath = Join-Path $repoRoot $OutputRoot
$packageName = "SamhainSecurity-$Version-$Runtime"
$packagePath = Join-Path $outputRootPath $packageName
$zipPath = Join-Path $outputRootPath "$packageName.zip"

function Assert-UnderRepo {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $repoPath = [System.IO.Path]::GetFullPath($repoRoot)
    if (-not $fullPath.StartsWith($repoPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside repository: $fullPath"
    }
}

Assert-UnderRepo $outputRootPath
Assert-UnderRepo $packagePath

New-Item -ItemType Directory -Path $outputRootPath -Force | Out-Null
if (Test-Path $packagePath) {
    Remove-Item -LiteralPath $packagePath -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$appProject = Join-Path $repoRoot "SamhainSecurity\SamhainSecurity.csproj"
$serviceProject = Join-Path $repoRoot "SamhainSecurity.Service\SamhainSecurity.Service.csproj"
$appOut = Join-Path $packagePath "app"
$serviceOut = Join-Path $packagePath "service"
$enginesOut = Join-Path $packagePath "engines"
$scriptsOut = Join-Path $packagePath "scripts"
$selfContainedValue = $SelfContained.ToString().ToLowerInvariant()

dotnet publish $appProject -c $Configuration -r $Runtime "--self-contained:$selfContainedValue" -o $appOut
dotnet publish $serviceProject -c $Configuration -r $Runtime "--self-contained:$selfContainedValue" -o $serviceOut

New-Item -ItemType Directory -Path $enginesOut -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot "engines\*") -Destination $enginesOut -Recurse -Force
New-Item -ItemType Directory -Path $scriptsOut -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot "scripts\install-local.ps1") -Destination $scriptsOut -Force
Copy-Item -Path (Join-Path $repoRoot "scripts\uninstall-local.ps1") -Destination $scriptsOut -Force
Copy-Item -Path (Join-Path $repoRoot "scripts\installer-plan.json") -Destination $scriptsOut -Force

$readme = @"
Samhain Security $Version portable package

Run:
  app\SamhainSecurity.exe

Optional service commands from an elevated terminal:
  service\SamhainSecurity.Service.exe install
  service\SamhainSecurity.Service.exe start
  service\SamhainSecurity.Service.exe status

Local install helper:
  scripts\install-local.ps1 -PackagePath . -StartService -CreateStartMenuShortcut
  scripts\uninstall-local.ps1 -RemoveShortcut -DisableStartup

External engines:
  Put sing-box.exe under engines\sing-box\
  Put awg-quick.exe under engines\amneziawg\
  Put portable wireguard.exe under engines\wireguard\ when needed.
  Official WireGuard for Windows is detected from Program Files.

Local user data is stored under APPDATA\SamhainSecurity.
"@

Set-Content -LiteralPath (Join-Path $packagePath "README-PORTABLE.txt") -Value $readme -Encoding UTF8

$files = Get-ChildItem -LiteralPath $packagePath -Recurse -File |
    ForEach-Object {
        [PSCustomObject]@{
            path = $_.FullName.Substring($packagePath.Length + 1).Replace("\", "/")
            bytes = $_.Length
        }
    }

$manifest = [PSCustomObject]@{
    product = "Samhain Security"
    version = $Version
    runtime = $Runtime
    configuration = $Configuration
    selfContained = $SelfContained
    createdAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    files = $files
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $packagePath "release-manifest.json") -Encoding UTF8

Compress-Archive -Path (Join-Path $packagePath "*") -DestinationPath $zipPath -Force

Write-Host "Portable package: $packagePath"
Write-Host "Archive: $zipPath"

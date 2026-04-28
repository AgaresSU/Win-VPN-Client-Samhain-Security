param(
    [string]$Version = "0.8.0",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$QtRoot = "C:\Qt\6.10.3\mingw_64"
$MingwRoot = "C:\Qt\Tools\mingw1310_64"
$PythonScripts = Join-Path $env:APPDATA "Python\Python313\Scripts"
$PackageRoot = Join-Path $RepoRoot "dist\SamhainSecurityNative-$Version-win-x64"
$AppOut = Join-Path $PackageRoot "app"
$ServiceOut = Join-Path $PackageRoot "service"
$DocsOut = Join-Path $PackageRoot "docs"
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

New-Item -ItemType Directory -Force -Path $AppOut, $ServiceOut, $DocsOut, $EnginesOut | Out-Null
Copy-Item -LiteralPath $QtExe -Destination $AppOut -Force
Copy-Item -LiteralPath $ServiceExe -Destination $ServiceOut -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "README.md") -Destination $PackageRoot -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "VERSION") -Destination $PackageRoot -Force
Copy-Item -Path (Join-Path $RepoRoot "docs\*") -Destination $DocsOut -Recurse -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot "assets") -Destination $PackageRoot -Recurse -Force
if (Test-Path (Join-Path $RepoRoot "engines")) {
    Copy-Item -Path (Join-Path $RepoRoot "engines\*") -Destination $EnginesOut -Recurse -Force
}

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
    createdAtUtc = (Get-Date).ToUniversalTime().ToString("O")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PackageRoot "release-manifest.json") -Encoding UTF8

Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath "$PackageRoot.zip" -Force

Write-Host "Package: $PackageRoot"
Write-Host "Archive: $PackageRoot.zip"

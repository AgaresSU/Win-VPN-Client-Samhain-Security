param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$QtRoot = "C:\Qt\6.10.3\mingw_64"
$MingwRoot = "C:\Qt\Tools\mingw1310_64"
$PythonScripts = Join-Path $env:APPDATA "Python\Python313\Scripts"
$BuildDir = Join-Path $RepoRoot "build\desktop-qt"

$env:Path = "$QtRoot\bin;$MingwRoot\bin;$PythonScripts;$env:Path"
$env:CMAKE_PREFIX_PATH = $QtRoot

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

Push-Location $RepoRoot
try {
    Invoke-Checked "cargo" @("test", "--workspace")
    Invoke-Checked "cargo" @("build", "--workspace", "--release")

    if (Test-Path $BuildDir) {
        Remove-Item -LiteralPath $BuildDir -Recurse -Force
    }

    Invoke-Checked "cmake" @(
        "-S", "apps\desktop-qt",
        "-B", $BuildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-DCMAKE_PREFIX_PATH=$QtRoot",
        "-DCMAKE_C_COMPILER=$MingwRoot\bin\gcc.exe",
        "-DCMAKE_CXX_COMPILER=$MingwRoot\bin\g++.exe"
    )

    Invoke-Checked "cmake" @("--build", $BuildDir)
}
finally {
    Pop-Location
}

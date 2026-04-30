# Stable Release Gates

Version: `1.4.7`

The stable package uses the `stable` update channel, SHA256 package integrity, extracted-package validation, packaged smoke checks, and a release evidence JSON file.

## Automated Gates

Run before tagging:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\fetch-runtime-bundle.ps1
.\scripts\prepare-runtime-bundle.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.4.7 -RunServiceStatus
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.4.7-win-x64 -ValidateOnly
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.4.7 -RequireStableChannel
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.4.7 -RequireStableChannel -InstalledVersion 9.9.9 -AllowDowngradeRecovery
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.4.7
.\scripts\test-privileged-service-readiness.ps1 -ExpectedVersion 1.4.7
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.7 -SkipLaunch
.\scripts\write-release-notes.ps1 -ExpectedVersion 1.4.7
.\scripts\smoke-adapter-path.ps1 -ExpectedVersion 1.4.7
.\scripts\smoke-package.ps1 -ExpectedVersion 1.4.7
```

After the release commit is tagged, generate release evidence:

```powershell
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.4.7 -Tag v1.4.7
```

The evidence file is written next to the package as:

```text
dist\SamhainSecurityNative-1.4.7-win-x64.release-evidence.json
```

Clean-machine evidence is written next to the package as:

```text
dist\SamhainSecurityNative-1.4.7-win-x64.clean-machine-evidence.json
```

Generated release notes are written next to the package as:

```text
dist\SamhainSecurityNative-1.4.7-win-x64.release-notes.md
```

## Evidence Contents

- release commit SHA;
- release tag;
- package folder path;
- archive path;
- update manifest path;
- archive SHA256 and size;
- runtime bundle lock and package state paths;
- runtime fetch script and archive SHA256 policy;
- engine inventory and runtime availability source;
- runtime health source and fallback status;
- package validation result;
- update-manifest verification result;
- update downgrade guard and explicit recovery override result;
- rollback policy and previous-package preservation evidence;
- signing readiness result;
- clean-machine evidence result;
- generated release notes result;
- protocol matrix and visual QA document paths;
- service protection transaction status and before/after snapshots;
- packaged smoke result;
- signing status.

## Signing Status

The `1.4.7` package is stable-channel and integrity-verified, but it remains marked as `unsigned-dev` until a production certificate is available. The package and update manifests keep that status explicit so operator tooling does not mistake it for a signed public installer.

## Update And Rollback Policy

Stable manifests require SHA256 archive verification, stable-channel verification, downgrade protection by default, and explicit recovery override for intentional downgrade recovery. Current-user install and repair preserve the previous package in `%APPDATA%\SamhainSecurity\rollback\previous-package`, and the packaged smoke/evidence scripts verify rollback dry-runs before release.

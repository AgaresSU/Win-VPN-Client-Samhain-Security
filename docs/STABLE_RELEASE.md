# Stable Release Gates

Version: `1.3.0`

The stable package uses the `stable` update channel, SHA256 package integrity, extracted-package validation, packaged smoke checks, and a release evidence JSON file.

## Automated Gates

Run before tagging:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.3.0 -RunServiceStatus
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.3.0 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.3.0
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.3.0 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.3.0
```

After the release commit is tagged, generate release evidence:

```powershell
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.3.0 -Tag v1.3.0
```

The evidence file is written next to the package as:

```text
dist\SamhainSecurityNative-1.3.0-win-x64.release-evidence.json
```

Clean-machine evidence is written next to the package as:

```text
dist\SamhainSecurityNative-1.3.0-win-x64.clean-machine-evidence.json
```

## Evidence Contents

- release commit SHA;
- release tag;
- package folder path;
- archive path;
- update manifest path;
- archive SHA256 and size;
- engine inventory and runtime availability source;
- runtime health source and fallback status;
- package validation result;
- update-manifest verification result;
- signing readiness result;
- clean-machine evidence result;
- service protection transaction status and before/after snapshots;
- packaged smoke result;
- signing status.

## Signing Status

The `1.3.0` package is stable-channel and integrity-verified, but it remains marked as `unsigned-dev` until a production certificate is available. The package and update manifests keep that status explicit so operator tooling does not mistake it for a signed public installer.

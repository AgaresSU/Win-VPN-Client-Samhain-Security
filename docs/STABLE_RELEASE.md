# Stable Release Gates

Version: `1.1.7`

The stable package uses the `stable` update channel, SHA256 package integrity, extracted-package validation, packaged smoke checks, and a release evidence JSON file.

## Automated Gates

Run before tagging:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.1.7 -RunServiceStatus
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.1.7 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.1.7
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.1.7 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.1.7
```

After the release commit is tagged, generate release evidence:

```powershell
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.1.7 -Tag v1.1.7
```

The evidence file is written next to the package as:

```text
dist\SamhainSecurityNative-1.1.7-win-x64.release-evidence.json
```

Clean-machine evidence is written next to the package as:

```text
dist\SamhainSecurityNative-1.1.7-win-x64.clean-machine-evidence.json
```

## Evidence Contents

- release commit SHA;
- release tag;
- package folder path;
- archive path;
- update manifest path;
- archive SHA256 and size;
- package validation result;
- update-manifest verification result;
- signing readiness result;
- clean-machine evidence result;
- packaged smoke result;
- signing status.

## Signing Status

The `1.1.7` package is stable-channel and integrity-verified, but it remains marked as `unsigned-dev` until a production certificate is available. The package and update manifests keep that status explicit so operator tooling does not mistake it for a signed public installer.

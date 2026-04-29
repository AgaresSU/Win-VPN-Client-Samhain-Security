# Release Candidate Gates

Version: `1.1.4`

The release candidate build adds update-manifest verification and repeatable evidence for package integrity.

## Automated Gates

Run before tagging:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.1.4 -RunServiceStatus
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.1.4 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.1.4
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.1.4 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.1.4
```

The update manifest verifier checks the published zip hash and size, extracts the archive into a temporary folder, and runs package validation against the extracted files.

## Release Evidence

For each release candidate, keep:

- release commit SHA;
- tag;
- package folder path;
- zip path;
- update manifest path;
- `validate-package` JSON output;
- `verify-update-manifest` JSON output;
- `smoke-package` JSON output.

## Remaining Stable Blockers

- Production code signing certificate and signed binaries.
- Privileged installer/service identity.
- Production engine/adaptor runtime bundle.
- External clean-machine Windows 10/11 matrix.
- Final updater policy for rollback and minimum supported version.

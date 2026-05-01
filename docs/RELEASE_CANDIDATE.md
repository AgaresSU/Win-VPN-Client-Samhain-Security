# Release Candidate Gates

Version: `1.5.1`

The release candidate build adds update-manifest verification and repeatable evidence for package integrity.

## Automated Gates

Run before tagging:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\fetch-runtime-bundle.ps1
.\scripts\prepare-runtime-bundle.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.5.1 -RunServiceStatus
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.5.1-win-x64 -ValidateOnly
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.5.1 -RequireStableChannel
.\scripts\test-update-rehearsal.ps1 -ExpectedVersion 1.5.1
.\scripts\test-public-updater-rollout.ps1 -ExpectedVersion 1.5.1
.\scripts\test-installer-skeleton.ps1 -ExpectedVersion 1.5.1
.\scripts\test-installer-toolchain.ps1 -ExpectedVersion 1.5.1
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.5.1
.\scripts\test-privileged-service-readiness.ps1 -ExpectedVersion 1.5.1
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.5.1 -SkipLaunch
.\scripts\write-release-notes.ps1 -ExpectedVersion 1.5.1
.\scripts\smoke-adapter-path.ps1 -ExpectedVersion 1.5.1
.\scripts\smoke-package.ps1 -ExpectedVersion 1.5.1
```

The update manifest verifier checks the published zip hash and size, extracts the archive into a temporary folder, and runs package validation against the extracted files.

## Release Evidence

For each release candidate, keep:

- release commit SHA;
- tag;
- package folder path;
- zip path;
- update manifest path;
- runtime bundle lock and package state path;
- runtime fetch script and archive SHA256 policy;
- `validate-package` JSON output;
- `verify-update-manifest` JSON output;
- `test-installer-skeleton` and `test-installer-toolchain` JSON output;
- generated release notes path;
- protocol matrix and visual QA docs;
- protection transaction evidence from service status;
- `smoke-package` JSON output.

## Remaining Stable Blockers

- Production code signing certificate and signed binaries.
- Privileged installer/service identity.
- External protocol smoke with the fetched engines and adapters.
- External clean-machine Windows 10/11 matrix.
- Final updater policy for rollback and minimum supported version.

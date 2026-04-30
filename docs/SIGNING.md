# Signing And Integrity

Version: `1.4.9`

Current status: `unsigned-dev`.

The package is prepared for a future signing pipeline but is not production-signed yet. The release manifest records the expected publisher and digest algorithm, and the package contains SHA256 hashes for key files.

Public updater publishing stays blocked until the production signing pipeline and signed-installer handoff are available. Internal archives can still be validated, rehearsed, and used for controlled testing.

## Included Integrity Files

- `release-manifest.json`
- `checksums.txt`
- `SamhainSecurityNative-<version>-win-x64.update-manifest.json`

`checksums.txt` covers:

- `app\SamhainSecurityNative.exe`
- `service\samhain-service.exe`
- `tools\local-ops.ps1`
- `tools\validate-package.ps1`
- `tools\smoke-package.ps1`
- `tools\verify-update-manifest.ps1`
- `tools\test-update-rehearsal.ps1`
- `tools\test-public-updater-rollout.ps1`
- `tools\write-release-evidence.ps1`
- `tools\write-release-notes.ps1`
- `tools\test-signing-readiness.ps1`
- `tools\test-privileged-service-readiness.ps1`
- `tools\write-clean-machine-evidence.ps1`
- `tools\prepare-runtime-bundle.ps1`
- `tools\fetch-runtime-bundle.ps1`
- `engine-inventory.json`
- `runtime-bundle.lock.json`
- `app\engines\runtime-bundle-state.json`
- `release-manifest.json`
- `README.md`
- `VERSION`

## Production Signing Target

The stable installer should:

- sign desktop, service, helper, and installer binaries;
- verify the package manifest before install;
- verify update manifests before applying updates;
- run the public updater rollout gate before public publishing;
- display publisher information as `Samhain Security`;
- refuse rollback to a lower trusted version unless recovery mode is explicit.

# Signing And Integrity

Version: `1.5.1`

Current status: `unsigned-dev`.

The package is prepared for a future signing pipeline but is not production-signed yet. The release manifest records the expected publisher and digest algorithm, and the package contains SHA256 hashes for key files.

Public updater publishing stays blocked until the production signing pipeline and signed-installer handoff are available. Internal archives can still be validated, rehearsed, and used for controlled testing.

## Included Integrity Files

- `release-manifest.json`
- `checksums.txt`
- `SamhainSecurityNative-<version>-win-x64.update-manifest.json`
- `installer\signing-policy.json`
- `installer\installer-build-plan.json`
- `installer\installer-handoff.json`

`checksums.txt` covers:

- `app\SamhainSecurityNative.exe`
- `service\samhain-service.exe`
- `tools\local-ops.ps1`
- `tools\validate-package.ps1`
- `tools\smoke-package.ps1`
- `tools\verify-update-manifest.ps1`
- `tools\test-update-rehearsal.ps1`
- `tools\test-public-updater-rollout.ps1`
- `tools\test-installer-skeleton.ps1`
- `tools\test-installer-toolchain.ps1`
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
- `installer\README.md`
- `installer\SamhainSecurityInstaller.wxs`
- `installer\installer-build-plan.json`
- `installer\signing-policy.json`
- `installer\installer-handoff.json`
- `release-manifest.json`
- `README.md`
- `VERSION`

## Production Signing Target

The stable installer should:

- sign desktop, service, helper, and installer binaries;
- verify the package manifest before install;
- verify update manifests before applying updates;
- run the public updater rollout gate before public publishing;
- run the signed-installer skeleton gate before public publishing;
- run the installer toolchain gate and keep unsigned MSI output local-only;
- display publisher information as `Samhain Security`;
- refuse rollback to a lower trusted version unless recovery mode is explicit.

## Signing Scaffold

`installer\signing-policy.json` declares the expected publisher, digest algorithm, timestamp requirement, secure certificate inputs, and the desktop, service, and installer signing targets. It intentionally keeps `publishAllowed` false until the production certificate is supplied.

`installer\installer-build-plan.json` declares the WiX 6.x local build path and `tools\test-installer-toolchain.ps1` performs the unsigned MSI dry-run when the toolchain is available. That MSI is evidence only; it is not public-release material until production signing is applied.

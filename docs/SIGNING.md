# Signing And Integrity

Version: `1.2.3`

Current status: `unsigned-dev`.

The package is prepared for a future signing pipeline but is not production-signed yet. The release manifest records the expected publisher and digest algorithm, and the package contains SHA256 hashes for key files.

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
- `tools\write-release-evidence.ps1`
- `tools\test-signing-readiness.ps1`
- `tools\write-clean-machine-evidence.ps1`
- `release-manifest.json`
- `README.md`
- `VERSION`

## Production Signing Target

The stable installer should:

- sign desktop, service, helper, and installer binaries;
- verify the package manifest before install;
- verify update manifests before applying updates;
- display publisher information as `Samhain Security`;
- refuse rollback to a lower trusted version unless recovery mode is explicit.

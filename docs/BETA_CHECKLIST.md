# Beta Checklist

Version: `1.4.8`

This checklist keeps beta readiness visible without adding complexity to the desktop UI.

## Automated Local Gates

Run before tagging a release:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\fetch-runtime-bundle.ps1
.\scripts\prepare-runtime-bundle.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.4.8 -RunServiceStatus
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.4.8-win-x64 -ValidateOnly
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.4.8 -RequireStableChannel
.\scripts\test-update-rehearsal.ps1 -ExpectedVersion 1.4.8
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.4.8
.\scripts\test-privileged-service-readiness.ps1 -ExpectedVersion 1.4.8
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.8 -SkipLaunch
.\scripts\write-release-notes.ps1 -ExpectedVersion 1.4.8
.\scripts\smoke-adapter-path.ps1 -ExpectedVersion 1.4.8
.\scripts\smoke-package.ps1 -ExpectedVersion 1.4.8
```

The smoke script validates package structure, SHA256 hashes, runtime bundle state, service status, current-user operations in dry-run mode, machine-scope service status/dry-runs, and packaged desktop launch.

## Manual Windows Matrix

- Windows 10, current user: install, status, repair, uninstall.
- Windows 10, administrator: install, status, repair, uninstall.
- Windows 11, current user: install, status, repair, uninstall.
- Windows 11, administrator: install, status, repair, uninstall.
- Restricted user: launch, import link, dry-run status, no unexpected privileged prompts.
- Reboot check: startup entry and user service task recover cleanly.

## Protocol Matrix

Detailed release rules live in `docs\PROTOCOL_MATRIX.md`.

- VLESS TCP REALITY: import, ping, proxy path, whole-computer path.
- Trojan: import, ping, proxy path.
- Shadowsocks: import, ping, proxy path.
- Hysteria2: import, ping, proxy path.
- TUIC: import, ping, proxy path.
- WireGuard: import, generated profile, adapter diagnostics.
- AmneziaWG: import, generated profile, adapter diagnostics.

## Beta Blockers

- Production signing certificate and certificate-backed service identity.
- External runtime protocol smoke with the fetched engines and adapters.
- Production WFP app-routing enforcement.
- Production-signed update manifest verification.
- External Windows 10/11 matrix evidence from clean machines.

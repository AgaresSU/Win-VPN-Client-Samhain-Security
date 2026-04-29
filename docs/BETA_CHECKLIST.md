# Beta Checklist

Version: `1.0.6`

This checklist keeps beta readiness visible without adding complexity to the desktop UI.

## Automated Local Gates

Run before tagging a release:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.0.6 -RunServiceStatus
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.0.6 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.0.6
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.0.6 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.0.6
```

The smoke script validates package structure, SHA256 hashes, service status, current-user operations in dry-run mode, and packaged desktop launch.

## Manual Windows Matrix

- Windows 10, current user: install, status, repair, uninstall.
- Windows 10, administrator: install, status, repair, uninstall.
- Windows 11, current user: install, status, repair, uninstall.
- Windows 11, administrator: install, status, repair, uninstall.
- Restricted user: launch, import link, dry-run status, no unexpected privileged prompts.
- Reboot check: startup entry and user service task recover cleanly.

## Protocol Matrix

- VLESS TCP REALITY: import, ping, proxy path, whole-computer path.
- Trojan: import, ping, proxy path.
- Shadowsocks: import, ping, proxy path.
- Hysteria2: import, ping, proxy path.
- TUIC: import, ping, proxy path.
- WireGuard: import, generated profile, adapter diagnostics.
- AmneziaWG: import, generated profile, adapter diagnostics.

## Beta Blockers

- Signed privileged installer and service identity.
- Production runtime bundle for engines and adapters.
- Production WFP app-routing enforcement.
- Production-signed update manifest verification.
- External Windows 10/11 matrix evidence from clean machines.

# Samhain Security Native 1.4.1

Version: `1.4.1`

Samhain Security `1.4.1` keeps the simple daily client unchanged and hardens the production runtime preparation path. Operators now get a locked runtime layout, package state evidence, and a validation command before public installer work continues.

## Included

- Compact Qt/QML shell with servers, add, settings, statistics, logs, and about sections.
- Clipboard import and add-subscription flow with saved subscription groups.
- Real service-side subscription parsing for VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG records when the supplied subscription contains them.
- Service-backed ping checks without synthetic latency fallback.
- Route modes for whole computer, selected apps only through the release-supported proxy-aware path, and except-selected apps documented as blocked until the signed WFP layer exists.
- Proxy path, whole-computer TUN foundation, WireGuard and AmneziaWG adapter planning, and service-owned rollback evidence.
- Tray, startup registration, `samhain://` handoff, redacted support bundle, update manifest, rollback slot, and release evidence scripts.
- Runtime bundle lock, package runtime state, packaged validation script, and SHA256/version evidence when runtime binaries are present.
- Release readiness docs for stable gates, protocol coverage, visual QA, security posture, and clean-machine checks.

## Artifacts

- `dist\SamhainSecurityNative-1.4.1-win-x64`
- `dist\SamhainSecurityNative-1.4.1-win-x64.zip`
- `dist\SamhainSecurityNative-1.4.1-win-x64.update-manifest.json`
- `dist\SamhainSecurityNative-1.4.1-win-x64.release-evidence.json`
- `dist\SamhainSecurityNative-1.4.1-win-x64.clean-machine-evidence.json`
- `dist\SamhainSecurityNative-1.4.1-win-x64.release-notes.md`

## Verification

The release gates are:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\prepare-runtime-bundle.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.4.1 -RunServiceStatus
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.4.1-win-x64 -ValidateOnly
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.4.1 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.4.1
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.1 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.4.1
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.4.1 -Tag v1.4.1
```

## Known Limits

- Production code signing certificate is not applied yet; the package remains `unsigned-dev`.
- Production runtime binaries must be supplied and validated on clean Windows machines for each protocol family.
- Transparent except-selected application routing remains blocked until the signed WFP layer is ready.
- Machine-scope writes require an elevated installer path; current-user operation remains the fallback.

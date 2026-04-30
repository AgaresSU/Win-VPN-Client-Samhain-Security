# Samhain Security Native 1.4.3

Version: `1.4.3`

Samhain Security `1.4.3` turns the packaged desktop shell into a real service-backed app session. The desktop now starts the bundled user-mode service automatically when the IPC pipe is missing, waits for readiness, and sends subscription, latency, and connection commands through the live service instead of dropping into UI-only fallback.

## Included

- Compact Qt/QML shell with servers, add, settings, statistics, logs, and about sections.
- Clipboard import and add-subscription flow with saved subscription groups.
- Real service-side subscription parsing for VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG records when the supplied subscription contains them.
- Service-backed ping checks without synthetic latency fallback.
- Route modes for whole computer, selected apps only through the release-supported proxy-aware path, and except-selected apps documented as blocked until the signed WFP layer exists.
- Proxy path, whole-computer TUN foundation, WireGuard and AmneziaWG adapter planning, and service-owned rollback evidence.
- Tray, startup registration, `samhain://` handoff, redacted support bundle, update manifest, rollback slot, and release evidence scripts.
- Runtime bundle fetch for sing-box `1.13.11`, Xray `26.3.27`, WireGuard for Windows `1.0.1`, and AmneziaWG `2.0.0`.
- Runtime bundle lock, package runtime state, packaged validation script, and SHA256/version evidence for staged runtime binaries.
- Desktop-managed user-mode service startup with packaged service path discovery and named-pipe readiness waiting.
- Bounded hostname resolution for service-backed latency checks so resolvable hosts get real TCP-connect timing without letting slow DNS block startup.
- Smoke validation that a launched desktop process brings up the service IPC endpoint.
- Release readiness docs for stable gates, protocol coverage, visual QA, security posture, and clean-machine checks.

## Artifacts

- `dist\SamhainSecurityNative-1.4.3-win-x64`
- `dist\SamhainSecurityNative-1.4.3-win-x64.zip`
- `dist\SamhainSecurityNative-1.4.3-win-x64.update-manifest.json`
- `dist\SamhainSecurityNative-1.4.3-win-x64.release-evidence.json`
- `dist\SamhainSecurityNative-1.4.3-win-x64.clean-machine-evidence.json`
- `dist\SamhainSecurityNative-1.4.3-win-x64.release-notes.md`

## Verification

The release gates are:

```powershell
cargo test --workspace
.\scripts\build.ps1
.\scripts\fetch-runtime-bundle.ps1
.\scripts\prepare-runtime-bundle.ps1
.\scripts\package.ps1
.\scripts\validate-package.ps1 -ExpectedVersion 1.4.3 -RunServiceStatus
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.4.3-win-x64 -ValidateOnly
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.4.3 -RequireStableChannel
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.4.3
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.3 -SkipLaunch
.\scripts\smoke-package.ps1 -ExpectedVersion 1.4.3
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.4.3 -Tag v1.4.3
```

## Known Limits

- Production code signing certificate is not applied yet; the package remains `unsigned-dev`.
- Fetched runtime binaries still need live protocol validation for each protocol family before public installer rollout.
- Transparent except-selected application routing remains blocked until the signed WFP layer is ready.
- Machine-scope writes require an elevated installer path; current-user operation remains the fallback.

# Samhain Security Native 1.5.1

Version: `1.5.1`

Samhain Security `1.5.1` adds the installer toolchain preflight on top of the production signing scaffold. The package now carries the installer handoff contract, signing policy, WiX skeleton, build plan, and unsigned MSI dry-run gate while keeping public publishing blocked until the production certificate and clean-machine installer rehearsal are available.

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
- Current sing-box DNS config format so proxy-path startup works with the bundled runtime instead of crashing on deprecated DNS fields.
- Isolated proxy-path smoke with optional operator-supplied subscription URL and deterministic fallback profile for offline package gates.
- TUN-path start gate for current-user packages without elevated installer-owned trusted service identity.
- TUN-path smoke with safe preview validation, elevation-gate proof, runtime-health gated status, restore, emergency restore, and package-scoped cleanup checks.
- Adapter-path start gate for WireGuard and AmneziaWG without elevated installer-owned trusted service identity.
- Adapter-path smoke with WireGuard and AmneziaWG import, preview redaction, adapter gate proof, dry-run lifecycle, runtime-health evidence, emergency restore, and package-scoped cleanup checks.
- Machine service storage policy for `%ProgramData%\SamhainSecurity` while current-user packages stay under `%APPDATA%\SamhainSecurity`.
- Explicit service readiness fields for identity source, signing source, privileged-service readiness, TUN path allowance, and adapter path allowance.
- Privileged service preflight with manifest validation, machine install dry-run, service readiness JSON checks, signature status, Program Files path checks, and optional installed-service validation.
- Machine service plan evidence for unrestricted service SID policy used by future service-scoped rules.
- Update rehearsal preflight with local archive hash verification, stable manifest validation, extracted-package validation, isolated previous-package snapshot, candidate apply, and rollback restore proof.
- Public updater rollout preflight with production-signing requirement, signed-installer handoff boundary, blocked unsigned publishing, and required evidence checks.
- Signed installer skeleton preflight with WiX project scaffold, signing policy, installer handoff contract, and blocked publishing proof.
- Installer toolchain preflight with WiX 6.x detection, optional local unsigned MSI dry-run, artifact hash/signature checks, and local-only output.
- Smoke validation that a launched desktop process brings up the service IPC endpoint.
- Release readiness docs for stable gates, protocol coverage, visual QA, security posture, and clean-machine checks.

## Artifacts

- `dist\SamhainSecurityNative-1.5.1-win-x64`
- `dist\SamhainSecurityNative-1.5.1-win-x64.zip`
- `dist\SamhainSecurityNative-1.5.1-win-x64.update-manifest.json`
- `dist\SamhainSecurityNative-1.5.1-win-x64.release-evidence.json`
- `dist\SamhainSecurityNative-1.5.1-win-x64.clean-machine-evidence.json`
- `dist\SamhainSecurityNative-1.5.1-win-x64.release-notes.md`

## Verification

The release gates are:

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
.\scripts\smoke-proxy-path.ps1 -ExpectedVersion 1.5.1
.\scripts\smoke-tun-path.ps1 -ExpectedVersion 1.5.1
.\scripts\smoke-adapter-path.ps1 -ExpectedVersion 1.5.1
.\scripts\smoke-package.ps1 -ExpectedVersion 1.5.1
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.5.1 -Tag v1.5.1
```

## Known Limits

- Production code signing certificate is not applied yet; the package remains `unsigned-dev`.
- Signed installer publishing remains blocked until the production certificate and clean-machine installer rehearsal are complete.
- Unsigned MSI dry-run output is local-only evidence and is not public-release material.
- Fetched runtime binaries still need live protocol validation for each protocol family before public installer rollout.
- Live TUN route creation remains opt-in through `smoke-tun-path.ps1 -AllowLiveTun` and requires a privileged trusted service environment.
- Live adapter service installation remains opt-in through `smoke-adapter-path.ps1 -AllowLiveAdapter` and requires a privileged trusted service environment.
- Transparent except-selected application routing remains blocked until the signed WFP layer is ready.
- Machine-scope writes require an elevated installer path; current-user operation remains the fallback.

# Samhain Security Native

Version: `1.3.6`

Native Windows secure tunneling client prototype built from a clean base.

## Stack

- Desktop UI: C++ / Qt 6 / QML.
- Core models and parsing: Rust.
- Service skeleton: Rust Windows service entry point placeholder.
- Protocol engines planned: sing-box, Xray-core, WireGuard, AmneziaWG.
- Build: CMake, Ninja, Cargo.

## First Run Scope

This release is the native foundation. It focuses on the product shell, simple daily UX, local models, persistence, and build/package flow.

Implemented through `1.3.6`:

- Happ-inspired Qt/QML shell with servers, add, settings, statistics, logs, and about sections.
- Compact subscription group and server rows without technical clutter.
- Global `Ctrl+V` import flow that recognizes subscription-like URLs from the clipboard.
- Add-subscription dialog with name and URL fields.
- Route mode selector: whole computer, selected apps only, or whole computer except selected apps.
- Connection state, speed, traffic, session timer, and service-backed latency checks.
- Rust core data models for subscriptions, servers, protocols, route modes, and basic URL parsing.
- Rust IPC and service skeleton crates for the future privileged core.
- Versioned named-pipe IPC foundation between the desktop shell and Rust service.
- Real service-side subscription import for direct links, subscription pages, plain/base64 payloads, and AWG JSON profiles.
- DPAPI-protected storage for subscription URLs and raw server configs.
- Service-backed subscription groups with expand/collapse and an overlay menu for refresh, latency checks, pinning, URL copy, edit, and delete.
- Subscription menu actions have exact service event checks, local fallback only for local profiles, operation status evidence, stored update intervals, and last-update status.
- Polished subscription and navigation action icons with SVG-backed refresh, speedometer, pin, clipboard, sliders, delete, globe, gear-shaped settings, statistics, logs, and about glyphs.
- Custom-drawn menu and action buttons that avoid native light hover states in the dark red graphite shell.
- Persisted selected server and compact grouped server rendering in the desktop shell.
- Service-backed latency probes with single-server and batch checks, DNS-aware TCP connect timing, stored probe timestamps, compact row results, and no synthetic fallback.
- Engine manager V1: bundled-engine discovery, lifecycle IPC, redacted config preview, process start/stop/restart hooks, log capture, and one-step crash retry.
- First proxy path: service-owned system proxy snapshot/apply/rollback, local mixed inbound on `127.0.0.1:20808`, advanced proxy status, and packaged `app/engines` discovery.
- Whole-computer TUN path foundation: sing-box TUN config generation, DNS hijack policy, TUN lifecycle IPC state, advanced TUN status, and rollback on stop or unrecovered crash.
- WireGuard and AmneziaWG adapter path: `.conf` generation, secret-redacted preview, required field validation, adapter lifecycle commands, dry-run diagnostics, and stop rollback.
- App routing policy foundation: selected/excluded app list, service-owned policy state, UI editor, IPC commands, validation, rollback, and clear limited-support status for transparent per-app routing.
- Polished app-routing editor with structured application rows, mode-specific state labels, and dark custom actions.
- Service readiness evidence for current identity, elevation, firewall gate, and app-routing enforcement gate.
- Protection layer foundation: service-owned kill switch/DNS/IPv6/watchdog policy state, emergency restore IPC, rollback on stop/crash, scoped firewall command planning, and explicit enforcement gating for privileged service runs.
- Desktop integration: tray status/menu, minimize-to-tray behavior, single-instance handoff, Windows startup toggle, and `samhain://` import handler registration.
- Desktop integration ownership: package operations now report expected and actual autostart/link-handler commands, detect drift from old installs, copy tools into the install root, and write `desktop-integration.json` during install/repair.
- Service telemetry: per-session traffic state, categorized service/engine logs, and redacted support export for diagnostics.
- Diagnostics final: support bundle now includes a compact health summary, recent-error report, app-routing evidence, service self-check, inventory, audit tail, and stable log categories without leaking tokens or raw configs.
- Update and rollback hardening: stable manifests now declare trusted SHA256 policy, downgrade protection, explicit recovery override, previous-package preservation, and local rollback evidence.
- UX polish: dark red graphite theme pass, responsive compact navigation, bundled app icon in the shell, and empty states for quiet screens.
- Package script for a local Windows distributable.
- Local operations script for current-user install, repair, uninstall, status, migration backup, and package integrity files.
- Beta hardening scripts for package validation, SHA256 verification, operation dry-runs, service status, and packaged desktop smoke launch.
- Stable update manifest, archive hash/size verification, extracted-package validation, release evidence output, and packaged gate tooling.
- Packaged signing readiness checks and clean-machine evidence generation for installer preparation.
- Installer-owned machine-scope service install, repair, status, and uninstall path with elevation gating, service recovery policy, and dry-run evidence.
- Service self-check, service-owned recovery evidence, and redacted rotated audit events for privileged action gating.
- Typed protection apply/rollback transactions with transaction-scoped rule names, before/after evidence, and service-owned emergency restore evidence.
- Engine bundle contract with exact packaged runtime paths, package/service inventories, SHA256 evidence, version probes, and protocol availability by runtime presence.
- Runtime health state with explicit metrics source, fallback counter labels, route path, last error, last successful handshake, and reconnect reason fields.
- Main shell polish with a calmer connection panel, compact server rows, and bottom quick actions.
- Compact subscription rows with secondary actions moved into a quiet menu and a cleaner add-subscription dialog.
- Simplified settings with daily controls up front and technical service actions grouped under advanced settings.
- Visual polish for navigation buttons, the connection power control, dark Windows title bar, and rendered country badges.
- Refined flag rendering, removed native navigation highlight bleed, and cleaned the power icon artifact.
- Calmer right connection panel with real Proxy/TUN route buttons, a flatter power control, and honest `n/a` latency when the service cannot measure.
- Dark-green connected state for the power glyph, status badge, and connection ring.
- Daily UX freeze with plain-language route chips, dark custom dialog buttons, quiet server actions, a documented visual QA checklist, and technical operations kept under advanced settings.
- Connection reliability pass: no local fake connected state when the service is unavailable, explicit connect/disconnect progress text, 8-second engine command timeout, blocked route-mode switching while connected, and clearer failure messages.
- App-routing design gate: release-supported, experimental, and compatibility evidence for whole-computer, selected-apps-only, and except-selected-apps modes, with transparent per-process routing kept blocked until the signed WFP layer exists.
- App-routing enforcement V1: selected-apps-only now runs as a release-supported proxy-aware route without enabling system proxy globally, with transaction rollback evidence in service state and support export.

Not implemented yet:

- Production signed installer UI and certificate-backed service identity.
- Actual production runtime binaries for every protocol family still need to be supplied and validated on clean Windows machines.
- Production WFP transparent per-process app-routing enforcement layer.
- Fully trusted signed service identity and privileged enforcement.
- Production code signing certificate and online updater service rollout.

## Build

```powershell
.\scripts\build.ps1
```

## Package

```powershell
.\scripts\package.ps1
```

The package is written to:

```text
dist\SamhainSecurityNative-1.3.6-win-x64
```

## Local Operations

After extracting the package, use:

```powershell
.\tools\local-ops.ps1 -Action Install
.\tools\local-ops.ps1 -Action Status
.\tools\local-ops.ps1 -Action Repair
.\tools\local-ops.ps1 -Action Rollback
.\tools\local-ops.ps1 -Action Uninstall
```

See `docs\LOCAL_OPERATIONS.md` and `docs\SIGNING.md` for install scope, storage, migration, and integrity notes.

## Package Checks

```powershell
.\scripts\validate-package.ps1 -ExpectedVersion 1.3.6 -RunServiceStatus
.\scripts\smoke-package.ps1 -ExpectedVersion 1.3.6
```

See `docs\BETA_CHECKLIST.md` for the manual Windows and protocol matrix.

## Stable Checks

```powershell
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.3.6 -RequireStableChannel
.\scripts\verify-update-manifest.ps1 -ExpectedVersion 1.3.6 -RequireStableChannel -InstalledVersion 9.9.9 -AllowDowngradeRecovery
.\scripts\test-signing-readiness.ps1 -ExpectedVersion 1.3.6
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.3.6 -SkipLaunch
.\scripts\write-release-evidence.ps1 -ExpectedVersion 1.3.6
```

See `docs\STABLE_RELEASE.md` and `docs\CLEAN_MACHINE_EVIDENCE.md` for the stable release checklist and external test evidence flow.

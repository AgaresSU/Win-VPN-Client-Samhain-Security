# Samhain Security Native

Version: `0.8.3`

Native Windows secure tunneling client prototype built from a clean base.

## Stack

- Desktop UI: C++ / Qt 6 / QML.
- Core models and parsing: Rust.
- Service skeleton: Rust Windows service entry point placeholder.
- Protocol engines planned: sing-box, Xray-core, WireGuard, AmneziaWG.
- Build: CMake, Ninja, Cargo.

## First Run Scope

This release is the native foundation. It focuses on the product shell, simple daily UX, local models, persistence, and build/package flow.

Implemented in `0.7.0`:

- Happ-inspired Qt/QML shell with servers, add, settings, statistics, logs, and about sections.
- Compact subscription group and server rows without technical clutter.
- Global `Ctrl+V` import flow that recognizes subscription-like URLs from the clipboard.
- Add-subscription dialog with name and URL fields.
- Route mode selector: whole computer, selected apps only, or whole computer except selected apps.
- Mock ping, connection state, speed, traffic, and session timer.
- Rust core data models for subscriptions, servers, protocols, route modes, and basic URL parsing.
- Rust IPC and service skeleton crates for the future privileged core.
- Versioned named-pipe IPC foundation between the desktop shell and Rust service.
- Real service-side subscription import for direct links, subscription pages, plain/base64 payloads, and AWG JSON profiles.
- DPAPI-protected storage for subscription URLs and raw server configs.
- Service-backed subscription groups with expand/collapse, update, rename, delete, and safe diagnostics copy actions.
- Persisted selected server and compact grouped server rendering in the desktop shell.
- Service-backed latency probes with single-server and batch checks, stored probe timestamps, compact row results, and local fallback.
- Engine manager V1: bundled-engine discovery, lifecycle IPC, redacted config preview, process start/stop/restart hooks, log capture, and one-step crash retry.
- First proxy path: service-owned system proxy snapshot/apply/rollback, local mixed inbound on `127.0.0.1:20808`, advanced proxy status, and packaged `app/engines` discovery.
- Whole-computer TUN path foundation: sing-box TUN config generation, DNS hijack policy, TUN lifecycle IPC state, advanced TUN status, and rollback on stop or unrecovered crash.
- WireGuard and AmneziaWG adapter path: `.conf` generation, secret-redacted preview, required field validation, adapter lifecycle commands, dry-run diagnostics, and stop rollback.
- App routing policy foundation: selected/excluded app list, service-owned policy state, UI editor, IPC commands, validation, rollback, and clear limited-support status for transparent per-app routing.
- Protection layer foundation: service-owned kill switch/DNS/IPv6/watchdog policy state, emergency restore IPC, rollback on stop/crash, scoped firewall command planning, and explicit enforcement gating for privileged service runs.
- Desktop integration: tray status/menu, minimize-to-tray behavior, single-instance handoff, Windows startup toggle, and `samhain://` import handler registration.
- Service telemetry: per-session traffic state, categorized service/engine logs, and redacted support export for diagnostics.
- Package script for a local Windows distributable.

Not implemented yet:

- Real service installation.
- Production protocol runtime bundle.
- Production WFP app-routing enforcement layer.
- Installer-managed service identity and full privileged enforcement.
- Code signing and online updater.

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
dist\SamhainSecurityNative-0.8.3-win-x64
```

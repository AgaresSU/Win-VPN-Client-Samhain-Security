# Samhain Security Native

Version: `0.7.1`

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
- Package script for a local Windows distributable.

Not implemented yet:

- Real tunnel connection.
- Real service installation.
- Real TUN/firewall/WFP operations.
- Real engine lifecycle.
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
dist\SamhainSecurityNative-0.7.1-win-x64
```

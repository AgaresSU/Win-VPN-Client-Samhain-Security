# Samhain Security Roadmap

Version baseline: `0.0.5`

## Product Goal

Build a premium Windows secure tunneling client that feels fast, reliable, privacy-oriented, and powerful enough for advanced users while staying simple for daily use.

## Competitive Bar

The product should match or exceed the standard Windows feature set users expect from mature privacy clients:

- One-click connect with smart protocol selection.
- Reliable kill switch and leak protection.
- Per-app and per-domain split tunneling.
- DNS filtering for ads, trackers, malware, and phishing.
- Multi-hop routes and obfuscated transports.
- Clear diagnostics, logs, health checks, and repair actions.
- Background service with tray control and auto-connect.
- Secure profile import, export, backup, and migration.
- Signed installer, auto-update, crash reporting, and release channels.

## Architecture Target

The app should be split into four layers:

- Desktop UI: WPF first, with a possible WinUI 3 migration after the core is stable.
- Local daemon: privileged Windows service that owns tunnels, firewall rules, DNS, routes, and engine lifecycle.
- Protocol engines: sing-box, WireGuard, AmneziaWG, Windows Native, and future plugin adapters.
- Control plane: subscription, server catalog, updates, telemetry opt-in, and remote config.

The desktop UI should never directly own long-running tunnels in the final architecture. It should call the daemon over a local named pipe or gRPC-over-named-pipe channel.

## Version Plan

### 0.0.x: Foundation

- Finish brand migration to Samhain Security.
- Add engine bootstrapper and portable engine folders.
- Add structured logs and per-profile diagnostics.
- Add admin elevation flow for actions that need privileged operations.
- Add profile import for VLESS links and WireGuard-style config files.
- Add real status tracking for all protocols.
- Add basic tray icon with connect, disconnect, status, and open app.

### 0.1.x: Reliable Tunnel Core

- Introduce Samhain Security background service.
- Move route, DNS, firewall, and engine lifecycle into the service.
- Add kill switch using Windows Filtering Platform rules.
- Add DNS leak protection and IPv6 leak protection.
- Add service recovery after sleep, network change, crash, and reboot.
- Add smart reconnect and pause timers.
- Add startup auto-connect and trusted/untrusted network rules.

### 0.2.x: Protocol Depth

- Harden VLESS TCP Reality with sing-box validation, logs, and generated configs.
- Support additional sing-box transports and inbound modes.
- Add WireGuard key generation, peer editing, and endpoint roaming.
- Add AmneziaWG advanced fields and config validation.
- Add multi-hop profiles using chained outbound routes.
- Add active probes for protocol availability and best route selection.

### 0.3.x: Security Suite

- Add DNS filtering with local blocklists and remote list updates.
- Add anti-phishing and malware domain categories.
- Add per-app split tunneling.
- Add per-domain routing rules.
- Add traffic counters and connection quality telemetry stored locally by default.
- Add secure profile vault with Windows Credential Manager or DPAPI-NG.

### 0.4.x: Product Polish

- Add installer, code signing, and Start Menu integration.
- Add auto-update channels: stable, beta, nightly.
- Add first-run onboarding and guided diagnostics.
- Add server catalog UI with favorites, latency, load, and tags.
- Add account/license integration if the product will have managed servers.
- Add translations and accessibility pass.

### 1.0: Public Release

- Security review.
- Driver/service hardening review.
- Installer signing and release pipeline.
- Regression suite on Windows 10 and Windows 11.
- Clean upgrade path from all `0.x` builds.
- Public documentation and support playbooks.

## Immediate Next Builds

### 0.0.4

- Done: tray icon.
- Done: "Run as administrator" relaunch action.
- Done: engine availability badges beside the protocol selector.

### 0.0.5

- Done: portable engine folder structure and README placeholders.
- Done: engine version detection.
- Done: repair suggestions when an engine is missing.

### 0.0.6

- Add persistent connection state model.
- Add structured JSON logs.
- Add export diagnostics bundle.

### 0.0.7

- Add background service prototype.
- Add local named-pipe API between UI and service.
- Move connect/disconnect into service for one protocol first.

## Design Direction

The UI should feel like a quiet security control center:

- Left rail: profiles, current connection, quick actions.
- Main panel: selected profile, route health, protocol status.
- Details drawer: logs, diagnostics, generated config preview.
- Tray-first daily workflow.
- No marketing pages inside the app.

## Engineering Rules

- Every update bumps the patch version.
- Every protocol action must have a diagnostic result.
- Long-running engines are supervised.
- Generated configs are stored under `%APPDATA%\SamhainSecurity\runtime`.
- User secrets are never written unencrypted unless required by an external engine, and then only to runtime files with minimal lifetime.
- The final daemon owns privileged operations, not the desktop UI.

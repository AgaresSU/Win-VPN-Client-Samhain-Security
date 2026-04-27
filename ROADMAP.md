# Samhain Security Roadmap

Version baseline: `0.1.3`

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

- Done: persistent connection state model.
- Done: structured JSON logs.
- Done: export diagnostics bundle.

### 0.0.7

- Done: background service prototype.
- Done: local named-pipe API between UI and service.
- Done: Windows Native connect/disconnect/status use the service when available, with desktop fallback.

### 0.1.0

- Done: Windows service host with install/start/stop/restart/status/uninstall commands.
- Done: desktop service control button for elevated install/start checks.
- Done: diagnostics now report installed service state and named-pipe availability separately.

### 0.1.1

- Done: protection policy fields on profiles.
- Done: desktop protection panel for kill switch and DNS leak protection staging.
- Done: service pipe actions for protection apply, remove, and status.
- Done: service-owned protection state under `%ProgramData%\SamhainSecurity\Service`.
- Done: diagnostics include protection policy status.

### 0.1.2

- Done: non-destructive firewall rule preview from the desktop app.
- Done: service-side Windows Firewall rule group for protection enforcement.
- Done: firewall profile outbound default snapshot and restore.
- Done: emergency `reset-protection` service command.
- Done: WireGuard/AmneziaWG endpoint extraction from pasted config for allow-list planning.

### 0.1.3

- Done: post-apply protection health check.
- Done: automatic rollback when firewall enforcement fails health checks.
- Done: background service watchdog for protection drift.
- Done: emergency reset button in the desktop protection panel.
- Done: protection audit log in JSONL format.

## Design Direction

The UI should feel like a quiet security control center:

- Left rail: profiles, current connection, quick actions.
- Main panel: selected profile, route health, protocol status.
- Details drawer: logs, diagnostics, generated config preview.
- Tray-first daily workflow.
- No marketing pages inside the app.

## Engineering Rules

- Every update bumps the version.
- Every protocol action must have a diagnostic result.
- Long-running engines are supervised.
- Generated configs are stored under `%APPDATA%\SamhainSecurity\runtime`.
- User secrets are never written unencrypted unless required by an external engine, and then only to runtime files with minimal lifetime.
- The final daemon owns privileged operations, not the desktop UI.

# Roadmap

Current version: `0.7.1`

This roadmap is the working contract for Samhain Security. Future implementation should follow this order unless a blocker is found and documented in the same commit.

## Product Rules

- The visible product name is always `Samhain Security`.
- The main screen stays simple: add or paste a subscription, choose a server, connect, see status and traffic.
- Subscription groups own the server list. Advanced filters, raw config, routing details, and diagnostics stay behind settings or advanced panels.
- The desktop app owns presentation, tray behavior, and user intent only.
- The Rust service owns privileged network actions, engine lifecycle, firewall policy, DNS policy, recovery, and audit logs.
- Protocol support should use proven engines where possible. Custom protocol code is allowed only for parsing, validation, storage, orchestration, and glue.
- Every shipped update increments the version.

## Release Gates

Each release commit should pass:

- `cargo test --workspace`
- `.\scripts\build.ps1`
- `.\scripts\package.ps1` before release tags
- packaged app smoke launch
- `samhain-service.exe status`
- no build output committed from `build`, `target`, or `dist`
- no secrets in logs, docs, tests, or package manifests
- no forbidden legacy branding in visible desktop UI strings

## Target Architecture

```text
Qt/QML desktop
  -> versioned local IPC
  -> Rust service
  -> engine manager
  -> sing-box / Xray / WireGuard / AmneziaWG adapters
  -> Windows routing, DNS, firewall, counters, and recovery
```

Storage target:

- public metadata: plain JSON with schema version;
- sensitive URLs, keys, and generated engine config: Windows DPAPI;
- logs: structured, rotated, redacted by default;
- migrations: one versioned migration step per storage schema change.

Routing modes:

- whole computer;
- selected apps only;
- whole computer except selected apps.

The app-routing mode is a dedicated milestone because true per-process transparent routing on Windows must be verified against WFP, driver, and engine constraints before it is presented as production-ready.

## Milestones

### 0.7.1 - Roadmap Lock

- Replace the loose plan with this execution roadmap.
- Keep the native Qt/Rust baseline intact.
- Keep versioning discipline active.

Done when the plan is committed, tagged, and pushed.

### 0.7.2 - Service IPC Foundation

- Implement a Windows named-pipe service channel.
- Add handshake, version negotiation, request IDs, command timeout, and event stream.
- Move app state reads through the service API.
- Keep desktop fallback only for development builds.
- Add tests for command/event compatibility.

Done when the desktop can request state and receive service events without reading service-owned files directly.

### 0.7.3 - Real Subscription Ingestion

- Fetch `http` and `https` subscription URLs.
- Parse plain links and base64 subscription payloads.
- Cover VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG records.
- Preserve unknown records without crashing.
- Save multiple subscriptions with names, URLs, update intervals, last update status, and parsed servers.
- Encrypt sensitive subscription material with DPAPI.
- Keep `Ctrl+V` import and add-dialog import as equal first-class flows.

Done when the supplied Samhain links can be imported, saved, refreshed, and rendered as grouped servers.

### 0.7.4 - Compact Subscription UI

- Replace mock servers with service-backed subscription groups.
- Add expand/collapse per subscription.
- Add update, rename, delete, and copy-safe diagnostics for a subscription.
- Persist selected subscription and selected server.
- Keep the center list compact, without extra ranking panels.
- Show errors inline without opening technical logs.

Done when a normal user can paste a link, pick a server, and understand status without opening advanced settings.

### 0.7.5 - Ping And Health Probes

- Implement cancellable probe queue.
- Add TCP connect latency and engine-assisted latency where available.
- Store stale probe results with timestamps.
- Add manual test and background refresh.
- Avoid visual clutter: show latency in rows and details only.

Done when each server can show `ms`, `n/a`, or a clear error state.

### 0.7.6 - Engine Manager V1

- Add engine discovery and bundled-engine directory rules.
- Generate redacted config previews for advanced settings.
- Start, stop, restart, and clean engine processes from the service.
- Capture stdout/stderr into structured logs.
- Add crash detection and simple retry policy.

Done when the service can run an engine with a generated config and return lifecycle state to the desktop.

### 0.7.7 - Proxy Path

- Implement local proxy inbound management.
- Connect through engine-backed VLESS TCP REALITY first.
- Add Trojan, Shadowsocks, Hysteria2, and TUIC as parser and engine support permits.
- Add system proxy enable/disable with rollback.
- Show upload/download counters from runtime data when available.

Done when one imported VLESS TCP REALITY server can create a working protected path without TUN.

### 0.7.8 - Whole Computer TUN Mode

- Add TUN config generation.
- Apply default-route and DNS policy from the service.
- Roll back routes, DNS, and proxy state on disconnect or crash.
- Add connection watchdog.
- Add runtime byte counters and session timer from real state.

Done when the whole-computer mode connects, disconnects, and recovers cleanly after process failure.

### 0.7.9 - WireGuard And AmneziaWG

- Add WireGuard config generation and adapter lifecycle.
- Add AmneziaWG config generation and adapter lifecycle.
- Validate endpoint, peer, DNS, MTU, and persistent keepalive.
- Add diagnostics for missing drivers or runtime binaries.

Done when imported WireGuard and AmneziaWG servers can be selected and started through the same UI.

### 0.8.0 - App Routing Modes

- Implement the three routing modes in service state and UI state.
- Add app picker, executable validation, and signed-path display.
- Implement the first production-safe route path for selected/excluded apps.
- If true transparent per-process routing needs a driver, keep the UI honest and mark unsupported combinations as unavailable.
- Add firewall/WFP rule application, rollback, and dry-run diagnostics.

Done when all three modes have clear behavior, service-owned policy, and rollback on failure.

### 0.8.1 - Protection Layer

- Add kill switch.
- Add DNS leak protection.
- Add IPv6 policy.
- Add reconnect and backoff.
- Add service watchdog and crash recovery.
- Add emergency restore command.

Done when disconnects, crashes, and network changes fail closed or restore cleanly according to user settings.

### 0.8.2 - Tray, Autostart, And Link Handling

- Add tray menu and connection status.
- Add launch on Windows startup.
- Add custom link handling for subscription import and autostart handoff.
- Add single-instance behavior.
- Add minimized-to-tray behavior.

Done when links can open Samhain Security directly and tray operation is reliable.

### 0.8.3 - Statistics, Logs, And Support Export

- Add real per-session traffic counters.
- Add rolling logs by category: desktop, service, engine, subscription, protection.
- Add support archive export with secrets redacted.
- Add health summary for support.

Done when a support bundle can be created without leaking keys, tokens, or raw subscription URLs.

### 0.8.4 - UX Polish

- Finish dark red / graphite cyberpunk visual direction without text glare.
- Use supplied app and tray icons consistently.
- Improve small-window and high-DPI layout.
- Add empty states and loading states.
- Keep advanced settings hidden behind one clear entry point.

Done when the main workflow feels clean, branded, and readable on common Windows display scales.

### 0.8.5 - Installer And Local Operations

- Add installer plan and service install/uninstall flow.
- Add per-user and per-machine storage decisions.
- Add migration from old local state.
- Add uninstall cleanup and emergency repair.
- Prepare signing pipeline.

Done when a non-developer machine can install, run, repair, and uninstall the app.

### 0.9.0 - Beta

- Freeze core UX.
- Run full protocol matrix.
- Run Windows 10 and Windows 11 smoke tests.
- Run restricted-user and admin-user tests.
- Fix all critical and high-severity issues.

Done when daily use is stable enough for controlled external testers.

### 0.9.5 - Release Candidate

- Complete security review.
- Complete updater manifest verification.
- Complete signing.
- Complete crash and diagnostics review.
- Complete documentation for operators and support.

Done when no known release-blocking issue remains.

### 1.0.0 - Stable

- Ship signed production package.
- Publish checksums.
- Preserve rollback path.
- Start maintenance cadence.

Done when Samhain Security is ready for normal users.

## Immediate Next Build Order

1. `0.7.2`: service IPC foundation.
2. `0.7.3`: real subscription ingestion.
3. `0.7.4`: compact subscription UI.
4. `0.7.5`: real ping and health probes.
5. `0.7.6`: engine manager.
6. `0.7.7`: first real proxy connection path.
7. `0.7.8`: whole-computer TUN path.
8. `0.7.9`: WireGuard and AmneziaWG path.
9. `0.8.0`: selected/excluded app routing.
10. `0.8.1`: protection layer.

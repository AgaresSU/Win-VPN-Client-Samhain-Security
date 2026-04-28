# Samhain Security Roadmap

Version baseline: `0.6.1`

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

The default UI should stay close to the simplicity of Happ: a small set of obvious actions, subscription/import handled automatically, and thin protocol settings hidden behind a dedicated advanced settings surface.

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

### 0.1.4

- Done: local subscription block in the desktop app.
- Done: connection page URL normalization to the main subscription API.
- Done: raw/base64 VLESS TCP Reality subscription import.
- Done: sing-box JSON outbound import for VLESS Reality profiles.
- Done: DPAPI-encrypted subscription source storage under `%APPDATA%\SamhainSecurity\subscriptions.json`.

### 0.1.5

- Done: AWG reserve page URL normalization to `/api/sub/{token}/awg`.
- Done: AmneziaWG JSON catalog import from ready `config_text` items.
- Done: endpoint extraction from LF/CRLF tunnel configs for WG/AWG allow-list planning.
- Done: multiple subscription sources preserved in encrypted local storage.

### 0.1.6

- Done: subscription source list in the desktop app.
- Done: update selected source, update all sources, and delete source actions.
- Done: masked subscription tokens in the UI source list.
- Done: clipboard detection for Samhain Security connection links.
- Done: `Ctrl+V` import when focus is outside text fields, while standard text copy/paste remains intact.

### 0.1.7

- Done: service-side tunnel supervisor for VLESS TCP Reality, WireGuard, and AmneziaWG actions.
- Done: desktop non-native protocol actions call the service first and fall back to local execution if unavailable.
- Done: service owns long-running `sing-box` processes.
- Done: service writes runtime tunnel configs under `%ProgramData%\SamhainSecurity\Service\runtime`.
- Done: engine placeholder folders are copied to both desktop and service publish outputs.

### 0.1.8

- Done: default UI begins moving toward a Happ-like simple daily mode.
- Done: protocol internals, engine paths, raw configs, DNS, and protection policy controls are grouped under `Расширенные настройки`.
- Done: per-user Windows startup toggle.
- Done: last successful profile tracking.
- Done: optional autoconnect of the last successful profile on launch.
- Done: app behavior settings stored under `%APPDATA%\SamhainSecurity\settings.json`.

### 0.1.9

- Done: daily status band at the top of the desktop screen.
- Done: selected profile, route, protocol, service readiness, protection state, startup mode, and latest connection outcome are visible without opening advanced settings.
- Done: connect, disconnect, status refresh, service check, protection apply, profile import, save, delete, and autoconnect events update the daily status band.
- Done: raw protocol configs and subscription secrets stay out of the daily status surface.

### 0.2.0

- Done: saved subscription selector in the desktop subscription block.
- Done: imported profiles remember their source subscription for clean switching.
- Done: server dropdown filters by the selected saved subscription and loads the chosen server profile.
- Done: last selected subscription is remembered in app behavior settings.
- Done: legacy VLESS/AWG imports are still shown with protocol-based fallback until the source is refreshed.

### 0.2.1

- Done: favorite server flag on profiles.
- Done: last successful connection timestamp on profiles.
- Done: server dropdown sorting by favorites, last used, then name.
- Done: quick best-server selection from the current subscription.

### 0.2.2

- Done: shared protocol profile validator.
- Done: VLESS Reality shape validation before save/connect.
- Done: WireGuard and AmneziaWG config validation before save/connect.
- Done: connection path stops locally with clear errors before invoking engines or service.

### 0.2.3

- Done: resume-from-sleep reconnect trigger.
- Done: network availability and address change reconnect triggers.
- Done: reconnect throttle to avoid repeated connection storms.
- Done: visible setting for automatic connection recovery.

### 0.2.4

- Done: tray menu action to connect selected server.
- Done: tray menu action to connect best ranked server.
- Done: current subscription server submenu in tray.
- Done: tray server menu refreshes when the server list changes.

### 0.2.5

- Done: portable packaging script for desktop and service outputs.
- Done: clean `dist/` output ignored by git.
- Done: package README and release manifest generation.
- Done: zip archive generation for handoff builds.

### 0.2.6

- Done: quick server checks from the current dropdown list.
- Done: saved server status and delay for ranking.
- Done: `Лучший` now prefers recently checked available servers.

### 0.2.7

- Done: automatic reserve-server retry after a failed connection attempt.
- Done: failed servers are temporarily deprioritized in the server list.
- Done: manual connect, autoconnect, and recovery flows can land on the working reserve server.

### 0.2.8

- Done: visible connection progress and detail text.
- Done: connection states for normal connect, reserve connect, success, and failure.

### 0.2.9

- Done: richer server dropdown with inline status.
- Done: favorites, last-used, latency, and failed status stay visible.

### 0.3.0

- Done: background server checks after launch and subscription refresh.
- Done: background checks save status without blocking the main UI.

### 0.3.1

- Done: optional automatic best-server mode.
- Done: manual connect, autoconnect, and recovery can prefer the ranked best server.

### 0.3.2

- Done: rename saved subscription sources.
- Done: enable or disable saved sources without deleting imported profiles.

### 0.3.3

- Done: quiet scheduled subscription refresh for enabled sources.
- Done: stale sources refresh on launch while keeping the previous local list if a refresh fails.

### 0.3.4

- Done: tray status, favorites submenu, update subscriptions action, and protection toggle.

### 0.3.5

- Done: common engine, admin, timeout, network, profile, and service failures map to simple user-facing messages.

### 0.3.6

- Done: first-run quick start card for importing a link from the clipboard.

### 0.3.7

- Done: installer preparation manifest.
- Done: local install and uninstall helper scripts for the packaged service.

### 0.3.8

- Done: optional connection watchdog.
- Done: periodic status checks after successful connect.
- Done: automatic recovery through the reserve-server flow when the active route drops.

### 0.3.9

- Done: selected profile health summary.
- Done: watchdog check/failure counters saved with profiles.
- Done: reset action for clearing server health and ranking state.

### 0.4.0

- Done: local install helpers now cover packaged service setup, optional startup entry, and Start Menu shortcut creation.
- Done: portable packages include install/uninstall helper scripts.

### 0.4.1

- Done: in-app environment readiness check for local data folders, service availability, privileges, and selected protocol engine.

### 0.4.2

- Done: quick repair action creates required local folders and attempts service install/start when elevated.

### 0.4.3

- Done: compact server catalog table with server, protocol, status, and endpoint columns.
- Done: selecting a table row loads the matching profile and server dropdown choice.

### 0.4.4

- Done: local connection history store under `%APPDATA%\SamhainSecurity\connection-history.json`.
- Done: connect, disconnect, and status actions append redacted history entries.

### 0.4.5

- Done: support export includes a support report, connection history, and redacted structured logs.

### 0.4.6

- Done: quiet subscription refresh uses a configurable interval and continues when one source fails.

### 0.4.7

- Done: daily status band now includes readiness and recent history summaries without exposing raw technical fields.

### 0.4.8

- Done: shared secret redaction protects UI logs, structured logs, connection state, connection history, and exported diagnostic logs.

### 0.4.9

- Done: release-candidate version bump and portable package defaults.
- Done: installer plan updated for local service, startup, and shortcut flow.

### 0.5.0

- Done: local installer copies package files into `%ProgramFiles%\Samhain Security` by default.
- Done: upgrade flow stops and replaces the previous service registration before reinstalling.
- Done: installer writes `install-manifest.json` with version, source package, app path, service path, and shortcut/startup choices.
- Done: installer supports Start Menu shortcut, Desktop shortcut, startup entry, in-place install, service start, and no-service mode.
- Done: uninstall helper removes the service, optionally removes shortcuts/startup/install files, and preserves `%APPDATA%\SamhainSecurity` by default.

### 0.5.1

- Done: engine manager catalog for sing-box, WireGuard, and AmneziaWG.
- Done: portable engine root and per-engine folders are created from the app.
- Done: engine versions and resolved paths are shown in the advanced panel.
- Done: detected engine paths can be applied to the current profile.
- Done: root package `engines\...` folders are detected in addition to app-local engine folders.

### 0.5.2

- Done: local runtime profile folders are swept when protocol services start.
- Done: service-owned runtime profile folders are swept when the service supervisor starts and stops.
- Done: WireGuard and AmneziaWG temporary config files are removed after connect/disconnect commands finish.
- Done: VLESS runtime configs are removed when the managed sing-box process stops or fails to start.

### 0.5.3

- Done: server catalog search for the current subscription list.
- Done: favorites-only filter and visible/total server count.
- Done: quick sort modes for smart, fast, favorite, recent, and name-based browsing.
- Done: manual server checks respect the currently visible catalog filter.

### 0.5.4

- Done: quick recommended server choice above the catalog.
- Done: quick favorite server choice from the current visible list.
- Done: quick recent server choice from the current visible list.
- Done: recommendation buttons keep search and favorites-only filters predictable.

### 0.5.5

- Done: server recommendation cards now explain the selection reason.
- Done: recommendation reasons include availability, delay, last check time, favorite state, and last-use time.
- Done: recommendation tooltips mirror the visible reason text for easier inspection.

### 0.5.6

- Done: active server catalog filters are shown in the counter line.
- Done: one-click reset clears search, favorites-only mode, and non-default sorting.
- Done: empty filtered lists are easier to understand and recover from.

### 0.5.7

- Done: server catalog sort mode is saved in app behavior settings.
- Done: favorites-only catalog preference is saved between sessions.
- Done: server search text remains temporary and starts clean on launch.

### 0.5.8

- Done: Enter in server search selects the first visible server.
- Done: Escape in server search clears the search text.
- Done: Enter or double-click in the server table connects the selected server.

### 0.5.9

- Done: right-clicking a server row selects it before opening row actions.
- Done: row actions can connect, add or remove favorite state, or copy the visible address.
- Done: the existing favorite button and row menu share the same save-and-refresh path.

### 0.6.0

- Done: first premium daily shell pass with left server categories, central catalog, and right connection panel.
- Done: category buttons switch between all, favorite, fast, recent, VLESS, and AWG server views.
- Done: the main connect action is promoted into a large dedicated control while technical settings stay below.

### 0.6.1

- Done: the active server category is visually highlighted in the left navigation.
- Done: the central catalog title follows the selected category.
- Done: manual search, favorites-only, or sort changes mark the catalog as a filtered view.

## Design Direction

The UI should feel like a quiet security control center:

- Left rail: profiles, current connection, quick actions.
- Main panel: selected profile, route health, protocol status.
- Details drawer: logs, diagnostics, generated config preview.
- Tray-first daily workflow.
- Default mode: one-click connect, subscription source, and status only.
- Advanced settings: protocol internals, engine paths, raw configs, DNS, and protection policy details.
- No marketing pages inside the app.

## Engineering Rules

- Every update bumps the version.
- Every protocol action must have a diagnostic result.
- Long-running engines are supervised.
- Generated configs are stored under `%APPDATA%\SamhainSecurity\runtime`.
- User secrets are never written unencrypted unless required by an external engine, and then only to runtime files with minimal lifetime.
- The final daemon owns privileged operations, not the desktop UI.

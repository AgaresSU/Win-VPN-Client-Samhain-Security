# Roadmap

Current version: `1.1.9`

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
- `.\scripts\validate-package.ps1 -RunServiceStatus`
- `.\scripts\verify-update-manifest.ps1 -RequireStableChannel` for stable tags
- `.\scripts\write-release-evidence.ps1` for stable tags
- `.\scripts\test-signing-readiness.ps1`
- `.\scripts\write-clean-machine-evidence.ps1`
- `.\scripts\smoke-package.ps1`
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

Status: shipped in `v0.7.1`.

### 0.7.2 - Service IPC Foundation

- Implement a Windows named-pipe service channel.
- Add handshake, version negotiation, request IDs, command timeout, and event stream.
- Move app state reads through the service API.
- Keep desktop fallback while service install/start remains a later milestone.
- Add tests for command/event compatibility.

Done when the desktop can request state and receive service events without reading service-owned files directly.

Status: shipped in `v0.7.2` with the first named-pipe endpoint and desktop fallback.

### 0.7.3 - Real Subscription Ingestion

- Fetch `http` and `https` subscription URLs.
- Parse plain links and base64 subscription payloads.
- Cover VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG records.
- Preserve unknown records without crashing.
- Save multiple subscriptions with names, URLs, update intervals, last update status, and parsed servers.
- Encrypt sensitive subscription material with DPAPI.
- Keep `Ctrl+V` import and add-dialog import as equal first-class flows.

Done when the supplied Samhain links can be imported, saved, refreshed, and rendered as grouped servers.

Status: shipped in `v0.7.3` for direct links, landing pages, default API profile, and AWG JSON profiles.

### 0.7.4 - Compact Subscription UI

- Replace mock servers with service-backed subscription groups.
- Add expand/collapse per subscription.
- Add update, rename, delete, and copy-safe diagnostics for a subscription.
- Persist selected subscription and selected server.
- Keep the center list compact, without extra ranking panels.
- Show errors inline without opening technical logs.

Done when a normal user can paste a link, pick a server, and understand status without opening advanced settings.

Status: shipped in `v0.7.4` with service-backed grouped subscriptions, expand/collapse, update, rename, delete, safe diagnostics copy, and persisted selected server state.

### 0.7.5 - Ping And Health Probes

- Implement cancellable probe queue.
- Add TCP connect latency and engine-assisted latency where available.
- Store stale probe results with timestamps.
- Add manual test and background refresh.
- Avoid visual clutter: show latency in rows and details only.

Done when each server can show `ms`, `n/a`, or a clear error state.

Status: shipped in `v0.7.5` with single and batch probe IPC, TCP-connect checks for IP endpoints, stored probe timestamps, compact row labels, background refresh, and local fallback when the service is unavailable.

### 0.7.6 - Engine Manager V1

- Add engine discovery and bundled-engine directory rules.
- Generate redacted config previews for advanced settings.
- Start, stop, restart, and clean engine processes from the service.
- Capture stdout/stderr into structured logs.
- Add crash detection and simple retry policy.

Done when the service can run an engine with a generated config and return lifecycle state to the desktop.

Status: shipped in `v0.7.6` with bundled-engine discovery, lifecycle IPC commands, redacted preview generation, service-owned process start/stop/restart, stdout/stderr log capture, crash detection, and a one-step retry policy. Adapter launches are intentionally reserved for `0.7.9`.

### 0.7.7 - Proxy Path

- Implement local proxy inbound management.
- Connect through engine-backed VLESS TCP REALITY first.
- Add Trojan, Shadowsocks, Hysteria2, and TUIC as parser and engine support permits.
- Add system proxy enable/disable with rollback.
- Show upload/download counters from runtime data when available.

Done when one imported VLESS TCP REALITY server can create a working protected path without TUN.

Status: shipped in `v0.7.7` with local mixed inbound generation, service-owned Windows proxy snapshot/apply/rollback, packaged `app/engines` discovery, proxy lifecycle IPC state, advanced UI status, and rollback on stop or unrecovered engine crash. Runtime byte counters remain on the next telemetry pass because they depend on the selected engine's metrics endpoint.

### 0.7.8 - Whole Computer TUN Mode

- Add TUN config generation.
- Apply default-route and DNS policy from the service.
- Roll back routes, DNS, and proxy state on disconnect or crash.
- Add connection watchdog.
- Add runtime byte counters and session timer from real state.

Done when the whole-computer mode connects, disconnects, and recovers cleanly after process failure.

Status: shipped in `v0.7.8` with sing-box TUN config generation, DNS hijack policy, auto-route and strict-route config, service-owned TUN lifecycle IPC state, advanced UI status, and rollback of proxy/TUN state on stop or unrecovered engine crash. Real byte counters remain on the telemetry milestone.

### 0.7.9 - WireGuard And AmneziaWG

- Add WireGuard config generation and adapter lifecycle.
- Add AmneziaWG config generation and adapter lifecycle.
- Validate endpoint, peer, DNS, MTU, and persistent keepalive.
- Add diagnostics for missing drivers or runtime binaries.

Done when imported WireGuard and AmneziaWG servers can be selected and started through the same UI.

Status: shipped in `v0.7.9` with WireGuard/AmneziaWG `.conf` generation, required adapter profile validation, secret-redacted previews, service-owned adapter start/stop commands, dry-run diagnostics, and generated-profile cleanup on stop. Production machines still need the matching runtime tool installed or bundled.

### 0.8.0 - App Routing Modes

- Implement the three routing modes in service state and UI state.
- Add app picker, executable validation, and signed-path display.
- Implement the first production-safe route path for selected/excluded apps.
- If true transparent per-process routing needs a driver, keep the UI honest and mark unsupported combinations as unavailable.
- Add firewall/WFP rule application, rollback, and dry-run diagnostics.

Done when all three modes have clear behavior, service-owned policy, and rollback on failure.

Status: shipped in `v0.8.0` with selected/excluded application storage, service-owned policy IPC, compact UI editor, exe path validation, lifecycle rollback, and honest limited-support status for transparent per-app routing. The next enforcement step is a dedicated WFP layer; unsupported combinations are not presented as fully supported.

### 0.8.1 - Protection Layer

- Add kill switch.
- Add DNS leak protection.
- Add IPv6 policy.
- Add reconnect and backoff.
- Add service watchdog and crash recovery.
- Add emergency restore command.

Done when disconnects, crashes, and network changes fail closed or restore cleanly according to user settings.

Status: shipped in `v0.8.1` with service-owned protection settings/state, kill switch/DNS/IPv6/watchdog policy modeling, scoped firewall command planning behind an explicit enforcement flag, emergency restore IPC, UI status in settings, and rollback on stop or unrecovered crash. Full fail-closed enforcement remains tied to the privileged installer/service identity and WFP layer.

### 0.8.2 - Tray, Autostart, And Link Handling

- Add tray menu and connection status.
- Add launch on Windows startup.
- Add custom link handling for subscription import and autostart handoff.
- Add single-instance behavior.
- Add minimized-to-tray behavior.

Done when links can open Samhain Security directly and tray operation is reliable.

Status: shipped in `v0.8.2` with tray icon/menu, minimize-to-tray behavior, single-instance activation handoff, Windows startup toggle, and `samhain://` import handler registration. Full installer ownership of protocol registration remains in the installer milestone.

### 0.8.3 - Statistics, Logs, And Support Export

- Add real per-session traffic counters.
- Add rolling logs by category: desktop, service, engine, subscription, protection.
- Add support export with secrets redacted.
- Add health summary for support.

Done when a support bundle can be created without leaking keys, tokens, or raw subscription URLs.

Status: shipped in `v0.8.3` with service-owned session traffic state, categorized log snapshots, a logs page filter, and a redacted support export folder containing manifest, state, logs, and health summary. Direct runtime byte counters from engine metrics remain a later precision upgrade because supported engines expose them differently.

### 0.8.4 - UX Polish

- Finish dark red / graphite cyberpunk visual direction without text glare.
- Use supplied app and tray icons consistently.
- Improve small-window and high-DPI layout.
- Add empty states and loading states.
- Keep advanced settings hidden behind one clear entry point.

Done when the main workflow feels clean, branded, and readable on common Windows display scales.

Status: shipped in `v0.8.4` with the dark red graphite theme pass, responsive compact navigation, smaller safe window bounds, bundled icon usage in the shell, tuned status panel sizing, and empty states for server, app, and log surfaces.

### 0.8.5 - Installer And Local Operations

- Add installer plan and service install/uninstall flow.
- Add per-user and per-machine storage decisions.
- Add migration from old local state.
- Add uninstall cleanup and emergency repair.
- Prepare signing pipeline.

Done when a non-developer machine can install, run, repair, and uninstall the app.

Status: shipped in `v0.8.5` with a package-bundled local operations script, current-user install/repair/uninstall/status flow, startup/link/task registration, conservative migration backup, storage decisions, unsigned-dev manifest metadata, and SHA256 package checksums. Signed privileged installer work remains for release candidate hardening.

### 0.9.0 - Beta

- Freeze core UX.
- Run full protocol matrix.
- Run Windows 10 and Windows 11 smoke tests.
- Run restricted-user and admin-user tests.
- Fix all critical and high-severity issues.

Done when daily use is stable enough for controlled external testers.

Status: shipped in `v0.9.0` as the first beta hardening pass with package validation, checksum verification, operation dry-runs, service status checks, packaged desktop smoke launch, beta checklist, and protocol/Windows matrix tracking. Clean-machine external evidence remains required before release candidate.

### 0.9.5 - Release Candidate

- Complete security review.
- Complete updater manifest verification.
- Complete signing.
- Complete crash and diagnostics review.
- Complete documentation for operators and support.

Done when no known release-blocking issue remains.

Status: shipped in `v0.9.5` with release candidate update manifest generation, archive hash/size verification, extracted package validation, packaged verifier tooling, RC evidence checklist, and signing/updater documentation. Production signing and privileged installer identity remain the primary blockers for stable.

### 1.0.0 - Stable

- Ship stable package manifest.
- Publish checksums.
- Preserve rollback path.
- Start maintenance cadence.

Done when Samhain Security is ready for normal users.

Status: shipped in `v1.0.0` with stable-channel package manifests, update-manifest verification, packaged release-evidence tooling, checksum publication, package smoke gates, and a documented unsigned-dev signing status. Production certificate signing and a privileged installer remain tracked as post-1.0 hardening items rather than hidden assumptions.

### 1.0.1 - Maintenance Readiness

- Add signing readiness inventory for package binaries.
- Add clean-machine evidence generation for operator test runs.
- Package the new readiness tools and cover them with checksums.
- Keep the desktop UX unchanged.

Done when a release package can report current signing state and generate machine-specific install-readiness evidence without performing a real install.

Status: shipped in `v1.0.1` with packaged signing readiness checks, clean-machine evidence generation, manifest wiring, checksum coverage, and stable release documentation updates.

### 1.0.2 - Main Shell Polish

- Refine the first screen around the server list and connection panel.
- Reduce visual glare and keep the dark red graphite direction.
- Add quiet bottom quick actions for clipboard import and subscription add.
- Keep advanced and technical actions out of the primary path.

Done when the main screen feels closer to the reference layout while preserving existing flows and package gates.

Status: shipped in `v1.0.2` with a calmer right connection panel, compact server rows, quieter action buttons, bottom quick actions, and versioned package validation.

### 1.0.3 - Subscription UX Polish

- Keep subscription rows compact.
- Move rename, diagnostics, and delete into a quiet actions menu.
- Clean up the add-subscription dialog styling.
- Keep paste and manual add as equally simple paths.

Done when the subscription list no longer feels like a technical control panel.

Status: shipped in `v1.0.3` with compact subscription actions, a dark add-subscription dialog, safer disabled add state, and versioned package validation.

### 1.0.4 - Settings Simplification

- Keep the daily settings page focused on mode, app list, autostart, and link handling.
- Hide service, engine, path, restore, and diagnostic actions under advanced settings.
- Group advanced settings by purpose instead of showing one long technical control row.
- Keep the dark red graphite style consistent across settings controls.

Done when a non-technical user can change the work mode without scanning service internals.

Status: shipped in `v1.0.4` with a simplified settings page, a dark combo and switch, and grouped advanced service operations.

### 1.0.5 - Visual Polish Pass

- Improve left navigation button styling.
- Replace the standard central connection button with a custom power control.
- Apply dark Windows title-bar styling.
- Render country badges without relying on emoji font support.
- Rebalance the selected-server card so text and badges do not collide.

Done when the five visual issues from the review screenshots are fixed in the packaged app.

Status: shipped in `v1.0.5` with prettier navigation, a custom translucent power button, a dark title bar, and QML-rendered country badges.

### 1.0.6 - Visual Cleanup Pass

- Replace circular country badges with oval flag badges.
- Remove left-side red strips where they read as visual noise.
- Remove native-button hover and focus glow from navigation.
- Redraw the power icon without masking artifacts.

Done when the review screenshots no longer show circular flag outlines, blue navigation glow, red side strips, or the power glyph artifact.

Status: shipped in `v1.0.6` with Canvas-rendered oval flags, custom navigation hit states, a cleaned power glyph, and quieter selected rows.

### 1.0.7 - Connection Panel And Honest Latency

- Reduce the right-panel glow and remove extra power-control circles.
- Make the Proxy and TUN chips real route-mode controls.
- Keep the power glyph in Samhain red instead of white.
- Remove synthetic latency values when the service cannot measure.
- Resolve DNS names before TCP latency probes.

Done when the connection panel reads darker, the route chips click, and latency shows only measured values or `n/a`.

Status: shipped in `v1.0.7` with a flatter connection dial, real Proxy/TUN route buttons, DNS-aware TCP latency checks, and no pseudo-ping fallback.

### 1.0.8 - Connected State Color

- Switch the active power glyph from Samhain red to dark green.
- Switch the connected connection ring from gray to dark green.
- Keep the disconnected and action states in the red graphite palette.

Done when enabled state is visually distinct without making the whole panel bright.

Status: shipped in `v1.0.8` with dark-green active power, status, and connection-ring indicators.

### 1.0.9 - Subscription Action Menu

- Replace the native subscription menu with an overlay popup that does not affect list layout.
- Add refresh, latency check, pin, URL copy, edit, and delete actions.
- Keep the menu compact, dark, and icon-led.

Done when the actions menu opens without an empty vertical artifact and mirrors the reference structure.

Status: shipped in `v1.0.9` with an overlay action menu, service-backed pinning, and protected URL copy.

### 1.0.10 - Dark Button Hover And Menu Icons

- Remove native light hover states from main-screen action buttons.
- Replace text/emoji menu glyphs with custom-drawn action icons.
- Make the subscription-menu latency check target the selected subscription.

Done when row action buttons stay in the dark graphite palette and the subscription menu uses clean matching icons.

Status: shipped in `v1.0.10` with custom action controls, Canvas menu icons, and subscription-scoped latency checks.

### 1.0.11 - Application Routing Dialog Polish

- Split application routing rows into application name, path, and mode-specific state.
- Replace remaining native controls in the application routing dialog with dark custom actions.
- Clarify empty states and mode descriptions for selected-app and excluded-app flows.

Done when the app list is scannable, mode-specific, and free of native light hover states.

Status: shipped in `v1.0.11` with structured application routing rows, a compact mode summary, and custom dark dialog controls.

### 1.1.2 - Service Readiness Evidence

- Add a service readiness snapshot for current identity, elevation, and enforcement gates.
- Expose app-routing enforcement requested/available fields with evidence strings.
- Show privileged-service readiness in advanced settings without applying system rules.
- Extend package validation and clean-machine evidence with service readiness checks.

Done when service status and release evidence explain exactly why app routing is gated.

Status: shipped in `v1.1.2` with service readiness telemetry, app-routing evidence, and package-level readiness checks.

### 1.1.3 - Subscription Action Reliability

- Keep subscription source URLs in the desktop state for local action fallback.
- Make the subscription action popup preserve its row target before closing.
- Let refresh, pin, URL copy, rename, and delete complete locally when the service is unavailable.
- Show clear status/log feedback instead of silent no-op behavior.

Done when every action in the subscription menu gives an observable result in both service-backed and local states.

Status: shipped in `v1.1.3` with local fallbacks and popup click reliability fixes.

### 1.1.4 - Action Icon Polish

- Replace rough Canvas menu glyphs with cleaner, centered action icons.
- Use a speedometer for latency checks, a recognizable pushpin for pinning, stacked documents for URL copy, a pencil for edit, and a polished trash can for delete.
- Replace sidebar text glyphs with clean line icons for add, servers, settings, statistics, logs, and about.
- Keep action icon strokes consistent with the graphite/red shell.

Done when subscription and sidebar actions read clearly without explaining the icons in text.

Status: shipped in `v1.1.4` with polished menu and navigation action glyphs.

### 1.1.5 - Settings Gear Icon

- Replace the settings navigation glyph with a clearly recognizable gear.
- Keep the icon in the same thin white line style as the rest of the sidebar.
- Preserve the dark graphite active-row styling without native light hover artifacts.

Done when the settings entry reads as a gear immediately in the sidebar.

Status: shipped in `v1.1.5` with a gear-shaped settings icon.

### 1.1.6 - Subscription Menu Icon Cleanup

- Replace rough refresh, pin, and copy glyphs with simpler readable line icons.
- Keep the action menu dark and compact without adding labels or extra controls.
- Preserve the existing working actions while improving only their visual form.

Done when refresh, pin, and copy can be recognized at menu size without visual noise.

Status: shipped in `v1.1.6` with cleaner subscription action menu icons.

### 1.1.7 - Reference-Matched Action Icons

- Redraw the full subscription action menu icon set after the provided reference.
- Use consistent thin gray strokes for refresh, latency, pin, clipboard copy, sliders/edit, and delete.
- Keep menu behavior unchanged while aligning the visual language with the target shell.

Done when every popup menu action uses the same readable reference-style glyph family.

Status: shipped in `v1.1.7` with reference-matched subscription action glyphs.

### 1.1.8 - SVG Action Icons

- Replace hand-drawn Canvas popup action icons with packaged SVG resources.
- Use stable SVG path geometry for refresh, latency, pin, clipboard copy, sliders/edit, and delete.
- Keep the menu behavior unchanged while avoiding hand-tuned Canvas arc drift.

Done when popup icons render from resource files instead of ad hoc Canvas geometry.

Status: shipped in `v1.1.8` with SVG-backed subscription action icons.

### 1.1.9 - Privileged Service Dry-Run Surface

- Add `tools\local-ops.ps1 -Scope Machine` for service status and dry-run operation planning.
- Define the future Windows service name, display name, target install root, service command, automatic start mode, recovery policy, and verification steps.
- Keep machine-scope `Install`, `Repair`, and `Uninstall` write operations blocked unless `-DryRun` is supplied.
- Include machine-scope dry-run checks in smoke and clean-machine evidence.
- Extend package manifests and validation gates so the privileged service plan is visible in release artifacts.
- Update local operations documentation with operator commands and the fail-fast rule.

Done when a package can prove the installer-managed service surface without modifying SCM, `Program Files`, firewall, routing, or data roots.

Status: shipped in `v1.1.9` with machine-scope service dry-run planning and package evidence.

### 1.2.0 - Installer-Owned Machine Service Install

- Convert the `1.1.9` dry-run plan into the first real elevated install path.
- Copy package files to the machine install root through a single installer-owned flow.
- Register `SamhainSecurityService` with a stable command, automatic start, failure restart, and explicit uninstall cleanup.
- Keep current-user install as a fallback developer path, but make the production path machine-scoped.
- Add rollback if service registration, file copy, or first status check fails.
- Add tests and package gates for dry run, real status, uninstall dry run, and repair dry run.

Done when an elevated operator can install, repair, inspect, and uninstall the service without manual SCM commands.

Status: planned.

### 1.2.1 - Service Identity And Recovery

- Run privileged network actions only when service identity, elevation, and signing state match policy.
- Move recovery, watchdog, and emergency restore ownership fully into the service.
- Persist service audit events with redaction and rotation.
- Add recovery policy evidence to status, support export, and release evidence.
- Add a service-side self-check command for named pipe, engine directory, storage, routes, DNS, and firewall capability.

Done when service status explains what is available, what is blocked, and which recovery path will run after a failure.

Status: planned.

### 1.2.2 - Enforcement Policy Planner

- Turn protection firewall plans into a typed apply/rollback transaction model.
- Add dry-run and apply evidence for DNS guard, IPv6 policy, kill switch, and emergency restore.
- Keep rule names scoped to Samhain Security and avoid broad allow rules.
- Add transaction IDs so applied rules can be rolled back precisely.
- Extend clean-machine evidence with before/after snapshots for enforcement runs.

Done when privileged protection can be applied and rolled back from one auditable transaction.

Status: planned.

### 1.2.3 - Production Engine Bundle Contract

- Define exact bundled runtime layout for sing-box, Xray, WireGuard, and AmneziaWG.
- Add SHA256 inventory, executable presence checks, and version probes.
- Fail clearly when a selected protocol lacks its required runtime.
- Keep raw configs and credentials redacted in logs and support bundles.
- Package operator documentation for replacing or updating engine binaries.

Done when protocol availability is determined by package inventory rather than assumptions.

Status: planned.

### 1.2.4 - Runtime Health And Counters

- Read real engine health and byte counters where the selected runtime exposes them.
- Keep the current service-session counters only as a fallback with a visible source label.
- Add reconnect reason, last error, last successful handshake, and current route path to service state.
- Add a compact statistics page that remains useful without cluttering the main screen.

Done when the right panel and statistics page distinguish live runtime metrics from fallback telemetry.

Status: planned.

### 1.2.5 - Subscription Operations Hardening

- Make refresh, pin, copy, rename, delete, and ping tests deterministic with service-backed and local-fallback paths.
- Add subscription import tests for the Samhain landing URL, AWG URL, base64 payloads, and direct links.
- Store update intervals and last-update status per subscription.
- Add cancellation and timeout behavior for slow or unavailable subscription hosts.
- Preserve the simple grouped UX: subscription row first, servers folded under it.

Done when subscription actions work predictably without requiring the user to open logs.

Status: planned.

### 1.3.0 - Daily UX Freeze

- Freeze the primary screen: add/paste, subscription group, server rows, connect button, status, latency, route chips, traffic.
- Remove or hide any technical controls that still leak into the daily flow.
- Keep advanced settings under one deliberate expansion point.
- Verify small window, high-DPI, and Russian text fit for all major screens.
- Keep the dark red graphite style without bright native hover artifacts.

Done when the app feels simple enough for a non-technical user and stable enough for visual QA screenshots.

Status: planned.

### 1.3.1 - Connection Reliability Pass

- Add connect-state timeouts, cancellation, and user-visible retry states.
- Make disconnect and emergency restore safe to call repeatedly.
- Add route-mode switching behavior while connected: block, reconnect, or apply live based on service capability.
- Add clearer user messages for missing engine, missing adapter, invalid config, denied privilege, and rollback.

Done when failed connects leave the system in a known state and the UI never pretends that a failed path is connected.

Status: planned.

### 1.3.2 - App Routing Design Gate

- Validate the final Windows approach for selected-app and excluded-app modes: WFP, engine process matching, driver requirements, and limitations.
- Keep unsupported combinations disabled with honest explanations.
- Add a compatibility matrix for Windows 10, Windows 11, restricted user, admin user, proxy path, TUN path, WireGuard, and AmneziaWG.
- Decide which combinations are release-supported and which remain advanced/experimental.

Done when app-routing promises match what the implementation can actually enforce.

Status: planned.

### 1.3.3 - App Routing Enforcement V1

- Implement the first supported per-application enforcement layer from the `1.3.2` decision.
- Apply rules from the privileged service only.
- Add transaction rollback, emergency restore, and support export evidence.
- Add UI state for whole computer, selected apps only, and whole computer except selected apps.
- Add tests for path validation, disabled apps, deleted executables, and failed apply/rollback.

Done when supported app-routing modes are enforced, not just described.

Status: planned.

### 1.3.4 - Diagnostics And Support Final

- Finalize log categories: desktop, service, engine, subscription, routing, protection, updater.
- Add one-click redacted support export from the app.
- Include package version, service status, engine inventory, subscription summary, route mode, and recent errors.
- Keep secrets, tokens, URLs, keys, and raw configs redacted by default.
- Add a compact health summary that support can read without parsing raw logs.

Done when a support bundle can diagnose most failures without leaking private material.

Status: planned.

### 1.3.5 - Tray, Startup, And Link Ownership

- Move startup and `samhain://` registration from ad hoc user integration into installer-owned registration where appropriate.
- Keep tray actions fast: show, connect/disconnect, selected server, status, quit.
- Add minimized-to-tray and background launch behavior to clean-machine evidence.
- Make external subscription handoff reliable when the app is already running.

Done when tray and link behavior survive install, repair, update, and uninstall.

Status: planned.

### 1.3.6 - Update And Rollback Hardening

- Verify update manifest signatures or trusted hashes before applying updates.
- Preserve previous working package for rollback.
- Add downgrade protection unless explicit recovery mode is used.
- Keep release evidence linked to archive hash, package hash, tag, commit, and signing state.
- Add operator docs for stable, beta, rollback, and emergency restore.

Done when updates are auditable and a bad update can be backed out cleanly.

Status: planned.

### 1.3.7 - Security Review And Abuse Resistance

- Review IPC authorization, service command surface, file permissions, registry writes, update trust, logging redaction, and engine config handling.
- Make service commands reject untrusted or malformed requests.
- Check that no local user can hijack service-owned paths or engine binaries.
- Add evidence for privilege boundaries and known limitations.
- Keep public UI simple; keep dangerous controls behind advanced settings and service policy.

Done when the package has a written security posture and release-blocking issues are either fixed or explicitly blocked.

Status: planned.

### 1.4.0 - Release-Ready Competitive Build

- Ship the simple daily UX, real subscription workflow, real protocol runtime checks, privileged service path, protected connect/disconnect, app-routing decision, diagnostics, tray, startup, and update evidence.
- Run Windows 10 and Windows 11 clean-machine tests for current-user fallback and machine install.
- Run protocol matrix for VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, WireGuard, and AmneziaWG according to bundled runtime availability.
- Run visual QA against the reference style without copying branding.
- Publish package, archive, update manifest, checksums, signing/readiness evidence, clean-machine evidence, and release notes.

Done when Samhain Security can be installed and used by normal Windows users with a simple flow, honest limitations, and no hidden privileged-network assumptions.

Status: planned.

## Immediate Next Build Order

1. `1.2.0`: turn machine-scope dry-run into installer-owned service install, repair, status, and uninstall.
2. `1.2.1`: service identity, recovery, and self-check evidence.
3. `1.2.2`: privileged enforcement transaction planner.
4. `1.2.3`: production engine bundle contract.
5. `1.2.4`: runtime health and counters.
6. `1.2.5`: subscription operations hardening.
7. `1.3.0`: daily UX freeze.
8. `1.3.1`: connection reliability pass.
9. `1.3.2`: app-routing design gate.
10. `1.3.3`: app-routing enforcement V1.
11. `1.3.4`: diagnostics and support final.
12. `1.3.5`: tray, startup, and link ownership.
13. `1.3.6`: update and rollback hardening.
14. `1.3.7`: security review and abuse resistance.
15. `1.4.0`: release-ready competitive build.

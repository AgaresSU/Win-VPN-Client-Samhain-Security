# Architecture

Version: `1.0.3`

## Components

```text
apps/desktop-qt
  C++ / Qt 6 / QML desktop shell

crates/core
  Rust models, parser, local subscription structures

crates/ipc
  Versioned Rust command, event, request, and response schema

crates/service
  Rust service skeleton, named-pipe IPC endpoint, future privileged operations owner

scripts/local-ops.ps1
  Current-user package operations for install, repair, uninstall, status, migration backup, and integration registration

scripts/validate-package.ps1 and scripts/smoke-package.ps1
  Beta package validation, checksum verification, dry-run operation checks, service status, and packaged desktop launch smoke

scripts/verify-update-manifest.ps1, scripts/test-signing-readiness.ps1, scripts/write-clean-machine-evidence.ps1, and scripts/write-release-evidence.ps1
  Stable update manifest verification, signing readiness inventory, clean-machine evidence output, archive hash/size checks, and release evidence output
```

## Direction

The desktop process is responsible for interaction, presentation, tray behavior, and simple local state. It must not own privileged networking or firewall policy in the final product.

The Rust service will own:

- engine lifecycle;
- TUN/system proxy operations;
- firewall and WFP rules;
- DNS leak protection;
- watchdog and recovery;
- audit logging;
- traffic statistics and redacted diagnostics;
- update and manifest verification hooks.

## Daily Flow

```text
Ctrl+V / Add subscription
  -> parse and save subscription
  -> render compact server list
  -> select server
  -> connect via service
  -> show speed, traffic, session time
```

The `1.0.3` build implements the shell, state model, versioned IPC envelopes, a Windows named-pipe service endpoint, real subscription ingestion, DPAPI-protected service storage, compact service-backed subscription groups, service-owned latency probes, Engine Manager V1, the first proxy path, the whole-computer TUN path foundation, the WireGuard/AmneziaWG adapter path, the app-routing policy foundation, the first protection layer, desktop integration, service-owned session traffic state, categorized log snapshots, redacted support export, responsive dark red graphite UI polish, calmer main-screen layout, quieter subscription actions, current-user package operations, repeatable package validation, stable update-manifest verification, release evidence output, signing readiness checks, and clean-machine evidence generation. Firewall enforcement remains gated for privileged service runs until the installer/service identity and WFP layer are complete.

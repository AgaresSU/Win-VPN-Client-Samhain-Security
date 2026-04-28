# Architecture

Version: `0.7.9`

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

The `0.7.9` build implements the shell, state model, versioned IPC envelopes, a Windows named-pipe service endpoint, real subscription ingestion, DPAPI-protected service storage, compact service-backed subscription groups, service-owned latency probes, Engine Manager V1, the first proxy path, the whole-computer TUN path foundation, and the WireGuard/AmneziaWG adapter path. Adapter profiles are generated as `.conf` files, required interface/peer fields are validated, secrets are redacted in previews, lifecycle commands are owned by the service, and stop rollback removes the generated profile after the adapter is stopped.

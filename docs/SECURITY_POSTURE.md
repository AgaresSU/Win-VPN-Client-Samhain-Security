# Security Posture

Version: `1.4.0`

Samhain Security is hardened for a current-user package plus an installer-owned privileged service path. The visible desktop stays simple, while risky network, routing, and recovery operations remain service-owned and gated by identity, elevation, signing state, and explicit policy.

## Trust Boundaries

- Desktop UI owns presentation, tray behavior, and user intent.
- The service owns subscription secrets, engine orchestration, route policy, protection policy, recovery, diagnostics, and audit evidence.
- Privileged network actions require an elevated, installer-owned, signed service identity.
- Current-user builds can preview and plan privileged actions, but they do not claim full firewall or transparent per-process enforcement.

## IPC Surface

The service rejects malformed or abusive requests before command dispatch:

- payload limit: 65536 bytes;
- request ID limit: 64 ASCII characters;
- route application limit: 64 entries;
- ping batch limit: 128 entries;
- unknown log categories are rejected;
- control characters and oversized command fields are rejected.

## Runtime Search

Engine discovery is bundled-only by default. The service ignores current directory and `SAMHAIN_ENGINE_DIR` unless `SAMHAIN_ALLOW_DEV_ENGINE_DIR` is explicitly enabled for development. Package validation checks this policy through service self-check evidence.

## Storage And Logs

Service storage is expected under user profile data roots or temp during tests. Support bundles, audit events, generated engine previews, and engine log snapshots are redacted by default. Raw subscription URLs and server configs remain protected before public state is returned.

## Known Limits Before Production Signing

- Production code signing is still pending.
- The privileged service identity remains gated until installed and signed.
- Transparent per-process routing still requires the signed WFP layer.
- Runtime binaries must be supplied and validated on clean Windows machines before public release.

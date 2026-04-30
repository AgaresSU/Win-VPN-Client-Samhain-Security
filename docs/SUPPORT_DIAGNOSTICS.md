# Support Diagnostics

Version: `1.4.7`

The support export is a redacted diagnostic package created by the service and surfaced from the desktop app. Its goal is to explain common failures without exposing subscription links, tokens, private keys, generated raw configs, or passwords.

## Bundle Files

- `manifest.json`: package index, version, service readiness, recovery owner, subscription operation status, and routing transaction status.
- `diagnostics-summary.json`: compact health summary for quick triage.
- `recent-errors.json`: recent state errors, warning/error logs, and failed audit events.
- `state.json`: redacted service state snapshot.
- `logs.json`: redacted categorized log snapshot.
- `engine-inventory.json`: bundled runtime inventory and availability.
- `app-routing.json`: route mode, selected applications, evidence, and transaction state.
- `service-self-check.json`: service identity, readiness checks, and recovery policy.
- `service-audit.json`: redacted audit tail.
- `health.txt`: short human-readable status summary.

## Log Categories

The log snapshot keeps stable categories even before entries exist: `manager`, `subscription`, `routing`, `updater`, `protection`, `adapter`, `proxy`, `tun`, `support`, `stdout`, and `stderr`.

## Redaction Rules

The exporter redacts query tokens, access tokens, private and preshared keys, public-key-like fields, passwords, UUID-like values, short IDs, and known key parameters before writing diagnostic files. The desktop app copies only the bundle path to the clipboard.

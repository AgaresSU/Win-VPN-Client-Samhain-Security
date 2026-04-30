# App Routing Matrix

Version: `1.4.8`

This document is the release contract for the three route modes in Samhain Security. It keeps the daily UI honest: a mode is marked supported only when the current build can actually enforce it.

## Decisions

- `whole-computer` is release-supported for the TUN path when the selected runtime and privileges are available.
- WireGuard and AmneziaWG are release-supported only as whole-computer adapter profiles in this build.
- `selected-apps-only` is release-supported only for proxy-aware applications that can be configured to use the local mixed proxy.
- In `selected-apps-only`, Samhain Security starts the local proxy and leaves the system proxy unchanged; only applications explicitly pointed to `127.0.0.1:20808` use the protected route.
- `selected-apps-only` transparent capture is experimental and blocked until a signed privileged WFP layer exists.
- `exclude-selected-apps` transparent bypass is experimental and blocked until a signed privileged WFP layer exists.
- Running as administrator alone does not make transparent per-process routing safe or complete.

## Compatibility

| Mode | Proxy-aware apps | TUN path | WireGuard | AmneziaWG | Current user | Admin | Windows 10 | Windows 11 | Release status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Whole computer | Manual proxy supported | Supported when runtime permits | Supported as adapter profile | Supported as adapter profile | Supported where runtime does not need elevation | Runtime dependent | Supported | Supported | Supported |
| Selected apps only | Supported when each app points to the local proxy | Blocked for transparent capture | Blocked | Blocked | Supported only as proxy-aware mode | Still blocked without WFP layer | Proxy-aware only | Proxy-aware only | Partially supported |
| Whole computer except selected apps | Not enough to bypass TUN/adapter traffic | Blocked | Blocked | Blocked | Blocked | Still blocked without WFP layer | Blocked | Blocked | Experimental |

## UI Rules

- The main screen may show the three simple mode names.
- Unsupported combinations must show a limited or experimental state, never a fake connected guarantee.
- Advanced settings may expose WFP, privileged service, and runtime notes.
- The support bundle must include policy status, evidence, compatibility lines, and the route mode.

## Evidence Keys

- `transparent_per_app=blocked`
- `wfp_layer=not-implemented`
- `release_supported_proxy_aware_apps=true`
- `proxy_aware_enforcement=<true|false>`
- `local_proxy_endpoint=127.0.0.1:20808`
- `requested=<true|false>`
- `available=<true|false>`

## Transaction State

- `proxy-aware-app-routing` can be `planned`, `dry-run`, `applied`, or `rolled-back`.
- Rollback clears the app-routing transaction and leaves the system proxy untouched.
- Missing executable paths are reported as evidence without enabling transparent per-process capture.

## Release Gate

`1.3.3` is complete when service state, desktop summary, support evidence, and this matrix all say the same thing.

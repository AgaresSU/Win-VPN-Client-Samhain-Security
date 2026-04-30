# Protocol Matrix

Version: `1.4.3`

This matrix keeps protocol readiness honest. The desktop shows only the compact server list; these details stay in docs, diagnostics, and advanced tooling.

## Runtime Contract

| Protocol family | Runtime | Package path | Release status |
| --- | --- | --- | --- |
| VLESS TCP REALITY | Xray or sing-box | `app\engines\xray\xray.exe`, `app\engines\sing-box\sing-box.exe` | Supported when the runtime binary is bundled and the subscription record is valid |
| Trojan | sing-box | `app\engines\sing-box\sing-box.exe` | Supported when the runtime binary is bundled and the subscription record is valid |
| Shadowsocks | sing-box | `app\engines\sing-box\sing-box.exe` | Supported when the runtime binary is bundled and the subscription record is valid |
| Hysteria2 | sing-box | `app\engines\sing-box\sing-box.exe` | Supported when the runtime binary is bundled and the subscription record is valid |
| TUIC | sing-box | `app\engines\sing-box\sing-box.exe` | Supported when the runtime binary is bundled and the subscription record is valid |
| WireGuard | WireGuard tools | `app\engines\wireguard\wireguard.exe` | Adapter profile generation and diagnostics are release-ready; production runtime validation is required |
| AmneziaWG | AmneziaWG tools | `app\engines\amneziawg\amneziawg.exe` | Adapter profile generation and diagnostics are release-ready; production runtime validation is required |

## Required Checks

- Import each supported subscription record type.
- Confirm the grouped server row renders protocol, host label, and measured or `n/a` latency.
- Run a single-server latency check and a batch latency check.
- Confirm no synthetic latency is shown when the service cannot measure.
- Confirm `runtime-bundle.lock.json` and `app\engines\runtime-bundle-state.json` are present in the package.
- Confirm `engine-inventory.json` marks each runtime as `available` or `missing`.
- Confirm support export redacts subscription URLs, keys, and raw configs.
- Confirm connect and disconnect either complete through the service or return a clear failure message.

## Routing Coverage

| Route mode | Release status | Evidence |
| --- | --- | --- |
| Whole computer | Release-supported where the TUN runtime is present and privileged policy checks pass | service runtime health, protection transaction, rollback state |
| Selected apps only | Release-supported through the proxy-aware path | app-routing policy state, local proxy state, transaction rollback |
| Whole computer except selected apps | Blocked until signed WFP layer exists | app-routing matrix and enforcement docs |

## External Matrix

Before a public installer, run this matrix on Windows 10 and Windows 11:

- Current-user install, repair, rollback, uninstall.
- Administrator machine-scope install, repair, rollback, uninstall.
- Subscription import from clipboard and add dialog.
- Protocol runtime launch for every bundled runtime.
- Crash recovery, emergency restore, and reconnect evidence.

# Engine Bundle Contract

Samhain Security does not implement network protocols from scratch. The desktop app and Rust service orchestrate proven runtime binaries, generate redacted configs, and decide availability from the package inventory.

Version: `1.4.1`

## Required Layout

Place production runtimes under the packaged `app\engines` directory:

| Runtime | Required path | Protocol records unlocked |
| --- | --- | --- |
| sing-box | `app\engines\sing-box\sing-box.exe` | VLESS TCP REALITY, Trojan, Shadowsocks, Hysteria2, TUIC, sing-box |
| Xray | `app\engines\xray\xray.exe` | VLESS TCP REALITY, Trojan |
| WireGuard | `app\engines\wireguard\wireguard.exe` | WireGuard |
| AmneziaWG | `app\engines\amneziawg\awg-quick.exe` | AmneziaWG |

Development builds may also use `SAMHAIN_ENGINE_DIR`, but release packages are validated against the layout above.

## Bundle Lock

`runtime-bundle.lock.json` is the source of truth for:

- runtime id, display name, engine kind, and production-required flag;
- packaged executable path;
- version probe arguments;
- protocol records unlocked by that runtime;
- upstream project metadata for operator-managed updates.

Run this before packaging:

```powershell
.\scripts\prepare-runtime-bundle.ps1
```

The command creates the expected local `engines` folders and writes `engines\runtime-bundle-state.json`. The state file is not committed, but it is copied into packages as `app\engines\runtime-bundle-state.json`.

## Inventory

`scripts\package.ps1` writes `engine-inventory.json` next to `release-manifest.json`. Each entry contains:

- runtime id and engine kind;
- required bundled path;
- executable presence;
- SHA256 and size when the binary is present;
- version probe result;
- protocol records that depend on that runtime.

The service exposes the same contract in `engine_catalog`. Support bundles include a redacted `engine-inventory.json` so operators can diagnose missing or stale runtime binaries without exposing subscription URLs, generated configs, or credentials.

## Updating Runtimes

1. Stop Samhain Security and the service.
2. Replace only the executable inside the runtime folder listed above.
3. Run `.\scripts\package.ps1 -Version <version>`.
4. Run `.\scripts\validate-package.ps1 -ExpectedVersion <version> -RunServiceStatus`.
5. Run `.\scripts\prepare-runtime-bundle.ps1 -PackageRoot <package-root> -ValidateOnly`.
6. Check `engine-inventory.json` and `app\engines\runtime-bundle-state.json` for SHA256, size, version status, and protocol availability.

Do not place raw subscriptions, private keys, generated configs, or credentials in `app\engines`.

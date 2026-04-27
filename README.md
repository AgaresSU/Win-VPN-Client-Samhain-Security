# Samhain Security

Version: `0.1.3`

Desktop secure tunneling client for Windows built with WPF and .NET 9.

## What it does

- Creates and updates per-user Windows native tunnel profiles.
- Supports Windows native tunnel types: IKEv2, SSTP, L2TP, PPTP, and Automatic.
- Supports VLESS TCP Reality through `sing-box`.
- Supports WireGuard through the official Windows `wireguard.exe` tunnel service.
- Supports AmneziaWG through an external `awg-quick.exe`-compatible backend.
- Includes an in-app diagnostics check for admin rights, Windows native cmdlets, `rasdial`, and external protocol engines.
- Includes a tray icon with quick open, connect, disconnect, diagnostics, admin relaunch, and exit actions.
- Shows protocol engine availability badges in the profile editor.
- Detects external engine versions in diagnostics and prints repair suggestions when an engine is missing.
- Persists connection state, writes structured JSONL logs, and exports diagnostics bundles.
- Includes a local Windows service host with named pipe API for Windows Native connect, disconnect, and status actions.
- Adds in-app service control for install/start checks when running elevated.
- Adds a protection policy panel for kill switch, DNS leak protection, firewall preview, and service-side enforcement.
- Applies protection with a dedicated Windows Firewall rule group and restores previous firewall defaults on removal.
- Adds service watchdog, post-apply health checks, automatic rollback, emergency reset, and JSONL protection audit logging.
- Stores service-owned protection state in `%ProgramData%\SamhainSecurity\Service\`.
- Connects and disconnects through `rasdial.exe`.
- Stores profile data in `%APPDATA%\SamhainSecurity\profiles.json`.
- Stores connection state in `%APPDATA%\SamhainSecurity\connection-state.json`.
- Stores structured logs in `%APPDATA%\SamhainSecurity\logs\`.
- Encrypts saved passwords, L2TP PSK values, and pasted WG/AWG configs with Windows DPAPI for the current user.

## External engines

VLESS Reality requires `sing-box.exe`. Put it in one of these places or select it in the app:

```text
.\engines\sing-box\sing-box.exe
%ProgramFiles%\sing-box\sing-box.exe
```

WireGuard requires the official WireGuard for Windows app:

```text
%ProgramFiles%\WireGuard\wireguard.exe
```

AmneziaWG requires an `awg-quick.exe`-compatible command line tool. Put it in one of these places or select it in the app:

```text
.\engines\amneziawg\awg-quick.exe
%ProgramFiles%\AmneziaWG\awg-quick.exe
```

VLESS/WG/AWG TUN or tunnel service operations may require administrator permissions.

Relative engine paths are resolved from the app executable directory first, so portable layouts such as `.\engines\sing-box\sing-box.exe` work after publishing.

The repository includes placeholder engine folders under `engines\`. They are copied to the publish output so a portable package can place binaries next to the app.

## Run

```powershell
dotnet run --project ".\SamhainSecurity\SamhainSecurity.csproj"
```

## Build

```powershell
dotnet build ".\SamhainSecurity.sln"
```

## Publish

```powershell
dotnet publish ".\SamhainSecurity\SamhainSecurity.csproj" -c Release -r win-x64 --self-contained false
dotnet publish ".\SamhainSecurity.Service\SamhainSecurity.Service.csproj" -c Release -r win-x64 --self-contained false
```

The published executable is `SamhainSecurity.exe` and will be under:

```text
SamhainSecurity\bin\Release\net9.0-windows\win-x64\publish\
```

The service executable is published under:

```text
SamhainSecurity.Service\bin\Release\net9.0-windows\win-x64\publish\
```

Run these commands from an elevated terminal when managing the service manually:

```powershell
.\SamhainSecurity.Service.exe install
.\SamhainSecurity.Service.exe start
.\SamhainSecurity.Service.exe status
.\SamhainSecurity.Service.exe protection-status
.\SamhainSecurity.Service.exe reset-protection
.\SamhainSecurity.Service.exe watchdog-check
.\SamhainSecurity.Service.exe stop
.\SamhainSecurity.Service.exe uninstall
```

The desktop app can also install/start the service through the `Служба` button when launched as administrator. If the service is not running, Windows Native actions fall back to direct local execution.

## Protection Policy

Version `0.1.3` hardens service-owned firewall enforcement. The desktop app can preview the rule plan, apply protection, query the current policy, remove it, or run an emergency reset.

When Kill switch is enabled, the service creates rules in the `Samhain Security Protection` group, stores the previous Windows Firewall outbound defaults, then switches Domain/Private/Public outbound policy to block. Removing or resetting protection deletes the group and restores the saved defaults.

DNS leak protection is enforced together with Kill switch in this build, so approved DNS resolvers are allow-listed before outbound blocking is enabled.

The service runs a protection watchdog every 30 seconds. If the rule group or outbound firewall defaults drift into an unsafe partial state, the service removes protection rules and restores the saved firewall defaults. Protection actions are written to `%ProgramData%\SamhainSecurity\Service\protection-audit.jsonl`.

## Versioning

Version is bumped on each follow-up update. Minor versions mark roadmap phases, and patch versions mark fixes and small additions, for example `0.1.0`, `0.1.1`, `0.1.2`.

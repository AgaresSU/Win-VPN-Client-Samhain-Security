# Samhain Security

Version: `0.5.3`

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
- Imports Samhain Security subscription links from the connection page or direct API URL, including raw/base64 VLESS lists and sing-box JSON profiles.
- Imports Samhain Security AWG reserve links from the connection page or direct API URL, including ready AmneziaWG `.conf` items.
- Adds a subscription source manager with masked tokens, update selected, update all, delete, clipboard import, and global paste recognition.
- Adds saved subscription switching and a server dropdown that loads the selected server profile.
- Adds server favorites, last-used tracking, and a quick best-server selector.
- Adds quick server checks with saved status and delay for smarter best-server selection.
- Adds automatic reserve-server retry when the first connection attempt fails.
- Adds clearer connection progress, richer server status, background checks, automatic best-server mode, source management, quiet subscription refresh, richer tray actions, friendly errors, a first-run card, and installer preparation scripts.
- Adds connection watchdog checks after successful connect and automatic recovery if the active route clearly drops.
- Adds a connection health summary and a server status reset action for the current list.
- Adds release-readiness checks, a quick repair action, a server catalog table, local connection history, safer support export, and updated local install helpers.
- Adds a proper local install/upgrade path with install root copy, service replacement, shortcuts, startup entry, and install manifest.
- Adds an engine manager for sing-box, WireGuard, and AmneziaWG with portable folder creation, version checks, and one-click path selection.
- Adds runtime config cleanup for temporary VLESS/WireGuard/AmneziaWG files after stop/disconnect and stale startup sweeps.
- Adds server catalog search, favorites-only filtering, visible counts, and quick sort modes for daily server switching.
- Adds pre-connect validation for VLESS Reality and WireGuard-style configs with clear local errors.
- Adds optional reconnect after resume or network changes for the last successful profile.
- Adds tray-first server selection with connect selected, connect best, and current server submenu.
- Adds a portable package script that publishes desktop and service binaries into a clean distributable folder and zip archive.
- Supervises VLESS, WireGuard, and AmneziaWG lifecycle through Samhain Security Service when it is running, with desktop fallback when the service is unavailable.
- Adds a simpler daily UI mode: startup/autoconnect toggles stay visible, while engine paths, raw configs, protocol internals, DNS, and protection controls live under `Расширенные настройки`.
- Adds a daily status band with selected profile, route, protocol, service readiness, protection state, and the current connection result.
- Stores service-owned protection state in `%ProgramData%\SamhainSecurity\Service\`.
- Stores service-owned runtime tunnel configs in `%ProgramData%\SamhainSecurity\Service\runtime\`.
- Connects and disconnects through `rasdial.exe`.
- Stores profile data in `%APPDATA%\SamhainSecurity\profiles.json`.
- Stores app behavior settings in `%APPDATA%\SamhainSecurity\settings.json`.
- Stores subscription sources in `%APPDATA%\SamhainSecurity\subscriptions.json` with URLs encrypted by Windows DPAPI for the current user.
- Stores connection state in `%APPDATA%\SamhainSecurity\connection-state.json`.
- Stores connection history in `%APPDATA%\SamhainSecurity\connection-history.json`.
- Stores structured logs in `%APPDATA%\SamhainSecurity\logs\`.
- Encrypts saved passwords, L2TP PSK values, and pasted WG/AWG configs with Windows DPAPI for the current user.

## External engines

VLESS Reality requires `sing-box.exe`. Put it in one of these places or select it in the app:

```text
.\engines\sing-box\sing-box.exe
..\engines\sing-box\sing-box.exe
%ProgramFiles%\sing-box\sing-box.exe
```

WireGuard requires the official WireGuard for Windows app:

```text
.\engines\wireguard\wireguard.exe
..\engines\wireguard\wireguard.exe
%ProgramFiles%\WireGuard\wireguard.exe
```

AmneziaWG requires an `awg-quick.exe`-compatible command line tool. Put it in one of these places or select it in the app:

```text
.\engines\amneziawg\awg-quick.exe
..\engines\amneziawg\awg-quick.exe
%ProgramFiles%\AmneziaWG\awg-quick.exe
```

VLESS/WG/AWG TUN or tunnel service operations may require administrator permissions.

Relative engine paths are resolved from the app executable directory and the package root, so portable layouts such as `.\engines\sing-box\sing-box.exe` and `..\engines\sing-box\sing-box.exe` work after publishing.

The repository includes placeholder engine folders under `engines\`. They are copied to the desktop and service publish outputs so a portable package can place binaries next to the owning executable.

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

Portable package:

```powershell
.\scripts\package-portable.ps1
```

Local package helper:

```powershell
.\scripts\install-local.ps1 -PackagePath ".\dist\SamhainSecurity-0.5.3-win-x64" -StartService -CreateStartMenuShortcut
```

Default install root is `%ProgramFiles%\Samhain Security`. The helper stops and replaces the previous service registration, copies the package to the install root, writes `install-manifest.json`, and preserves `%APPDATA%\SamhainSecurity`.

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

## Service-Supervised Protocols

Version `0.1.7` moves VLESS TCP Reality, WireGuard, and AmneziaWG connect/disconnect/status actions behind the local Samhain Security Service when it is available. The desktop app sends the selected profile over the local named pipe, and the service owns privileged engine execution and long-running `sing-box` processes.

If the service is unavailable, the desktop app keeps the previous local execution path as a fallback. This keeps portable/dev builds usable while moving the production architecture toward a simple UI that delegates privileged work to the daemon.

## Daily Mode

Version `0.1.9` continues simplifying the desktop screen. The default view keeps subscription import, profile choice, startup/autoconnect toggles, the live daily status band, and connect/disconnect actions visible. Low-level protocol and protection fields are still available, but they are grouped under `Расширенные настройки`.

`Запускать с Windows` writes a per-user startup entry under the current user's Run key. `Подключать последний профиль` remembers the last successful profile and reconnects it on launch.

The daily status band summarizes the current profile, endpoint, protocol, service readiness, selected protection options, startup mode, and the latest connection outcome without exposing raw configs or tokens.

## Protection Policy

Version `0.1.3` hardens service-owned firewall enforcement. The desktop app can preview the rule plan, apply protection, query the current policy, remove it, or run an emergency reset.

When Kill switch is enabled, the service creates rules in the `Samhain Security Protection` group, stores the previous Windows Firewall outbound defaults, then switches Domain/Private/Public outbound policy to block. Removing or resetting protection deletes the group and restores the saved defaults.

DNS leak protection is enforced together with Kill switch in this build, so approved DNS resolvers are allow-listed before outbound blocking is enabled.

The service runs a protection watchdog every 30 seconds. If the rule group or outbound firewall defaults drift into an unsafe partial state, the service removes protection rules and restores the saved firewall defaults. Protection actions are written to `%ProgramData%\SamhainSecurity\Service\protection-audit.jsonl`.

## Subscriptions

Version `0.1.6` adds local subscription import. Paste the Samhain Security connection page URL, AWG reserve page URL, or a direct `/api/sub/...` URL into the `Подписка` block and press `Обновить`.

The app normalizes connection page links to the matching API subscription, imports VLESS TCP Reality profiles and AmneziaWG reserve configs, merges repeated updates into existing profiles, and keeps local engine/protection preferences when an imported profile already exists. Subscription URLs are saved encrypted with DPAPI and raw node data is not written to the UI log.

The subscription block can manage multiple sources. Tokens are masked in the source list, `Все` refreshes every saved source, and `Буфер` imports a recognized connection link from the clipboard. Standard text fields keep normal copy/paste behavior; when focus is outside text input, `Ctrl+V` can import a recognized subscription link directly.

Version `0.2.0` adds a saved subscription selector and a server dropdown. Imported profiles remember their source, the app remembers the last selected subscription, and loading a server from the dropdown fills the active profile without exposing raw config text.

Version `0.2.1` adds lightweight server ranking. Favorite servers float to the top, recently connected servers follow, and the `Лучший` action selects the best current candidate from the filtered list.

Version `0.2.2` adds local protocol validation before connect. VLESS Reality profiles are checked for UUID, port, SNI, public key, and Short ID shape; WireGuard and AmneziaWG configs are checked for required sections, keys, Endpoint, size, and invalid characters before the engine or service is called.

Version `0.2.3` adds a simple recovery loop. When Windows resumes from sleep or the network changes, the app can reconnect the last successful profile with a short delay and a 30-second throttle. The behavior is controlled by `Восстанавливать подключение`.

Version `0.2.4` expands tray-first daily use. The tray menu can connect the selected server, connect the best currently ranked server, or pick one of the current subscription servers from the `Серверы` submenu.

Version `0.2.5` adds a portable packaging script. It publishes the desktop app and service into `dist\SamhainSecurity-0.2.5-win-x64\`, copies engine placeholders, writes a portable README, creates a release manifest, and produces a zip archive.

Version `0.2.6` adds quick server checks. The server dropdown can check the current subscription list, remember the latest status and delay, and use that signal when selecting `Лучший`.

Version `0.2.7` adds automatic reserve-server retry. When a connection attempt fails, the app can mark that server as temporarily failed and try the next best servers from the current subscription list.

Versions `0.2.8` through `0.3.7` complete the next daily-use pass: visible connection progress, richer server status, background checks, automatic best-server mode, source rename/enable controls, quiet subscription refresh, tray favorites and update actions, friendlier errors, first-run guidance, and installer preparation scripts.

Version `0.3.8` adds connection watchdog mode. After a successful connect, the app periodically checks the active profile status and triggers recovery with reserve-server selection if the route clearly drops.

Version `0.3.9` adds a health summary for the selected profile, tracks watchdog checks/failures, and adds `Сброс` for clearing server health and ranking state in the current list.

Version `0.4.9` is a release-candidate polish pass. It adds in-app environment readiness checks, a safe quick repair path for local folders and the service, a compact server table for switching between subscription servers, local connection history, redacted support bundles, and install helpers for service/start-menu setup.

Version `0.5.0` starts the beta packaging track. The local installer now performs an install-root copy, handles upgrade service replacement, can create Start Menu/Desktop shortcuts, can enable startup, writes an install manifest, and uninstalls without deleting user data unless install-file removal is explicitly requested.

Version `0.5.1` adds the first engine manager pass. The advanced panel now shows sing-box, WireGuard, and AmneziaWG status/version/path, creates portable engine folders, opens the folder for manual drop-in, and can apply a detected engine path to the selected profile.

Version `0.5.2` tightens runtime config handling. Temporary plaintext engine configs are removed after WireGuard/AmneziaWG commands, after sing-box stops, and stale runtime profile folders are swept on app/service startup.

Version `0.5.3` improves daily server selection. The server catalog now supports search, favorites-only filtering, visible/total counts, and sort modes for smart, fast, favorite, recent, and name-based browsing.

## Versioning

Version is bumped on each follow-up update. Minor versions mark roadmap phases, and patch versions mark fixes and small additions, for example `0.1.0`, `0.1.1`, `0.1.2`.

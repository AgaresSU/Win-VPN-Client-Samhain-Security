# Samhain VPN Client Windows

Version: `0.0.1`

Desktop VPN client for Windows built with WPF and .NET 9.

## What it does

- Creates and updates per-user Windows VPN profiles.
- Supports Windows native VPN tunnel types: IKEv2, SSTP, L2TP, PPTP, and Automatic.
- Supports VLESS TCP Reality through `sing-box`.
- Supports WireGuard through the official Windows `wireguard.exe` tunnel service.
- Supports AmneziaWG through an external `awg-quick.exe`-compatible backend.
- Connects and disconnects through `rasdial.exe`.
- Stores profile data in `%APPDATA%\VpnClientWindows\profiles.json`.
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

## Run

```powershell
dotnet run --project ".\VpnClientWindows\VpnClientWindows.csproj"
```

## Build

```powershell
dotnet build ".\VpnClientWindows.sln"
```

## Publish

```powershell
dotnet publish ".\VpnClientWindows\VpnClientWindows.csproj" -c Release -r win-x64 --self-contained false
```

The published executable will be under:

```text
VpnClientWindows\bin\Release\net9.0-windows\win-x64\publish\
```

## Versioning

Patch version is bumped on each follow-up update: `0.0.1`, `0.0.2`, `0.0.3`, and so on.

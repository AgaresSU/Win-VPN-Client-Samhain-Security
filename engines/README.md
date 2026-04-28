Place runtime binaries here for local packaging.

Recognized names:

- `sing-box.exe`
- `xray.exe`
- `wireguard.exe`, `wg.exe`, `wireguard-go.exe`
- `amneziawg.exe`, `awg.exe`, `awg-go.exe`

The package script copies this folder to `app/engines` so the service can discover bundled engines next to the desktop executable.

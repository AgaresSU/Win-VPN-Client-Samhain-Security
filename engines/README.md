Place runtime binaries here for local packaging.

Required layout:

- `sing-box\sing-box.exe`
- `xray\xray.exe`
- `wireguard\wireguard.exe`
- `amneziawg\amneziawg.exe`

The package script copies this folder to `app\engines` so the service can discover bundled runtimes next to the desktop executable.

Use this command before packaging to create the expected folders and write local runtime state:

```powershell
.\scripts\fetch-runtime-bundle.ps1
.\scripts\prepare-runtime-bundle.ps1
```

Use this command when validating a package:

```powershell
.\scripts\prepare-runtime-bundle.ps1 -PackageRoot .\dist\SamhainSecurityNative-1.4.6-win-x64 -ValidateOnly
```

`runtime-bundle.lock.json` is the source of truth for runtime ids, executable paths, version probes, and protocol coverage. Do not place subscriptions, private keys, generated configs, or credentials in this folder.

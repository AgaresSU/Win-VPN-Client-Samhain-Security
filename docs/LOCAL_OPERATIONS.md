# Local Operations

Version: `1.1.9`

The Windows package includes `tools\local-ops.ps1` for current-user install, repair, uninstall, and status checks before the signed privileged installer is ready.

## Commands

Run these commands from the extracted package root:

```powershell
.\tools\local-ops.ps1 -Action Install
.\tools\local-ops.ps1 -Action Repair
.\tools\local-ops.ps1 -Action Status
.\tools\local-ops.ps1 -Action Uninstall
```

Use `-DryRun` to inspect actions without writing registry keys, tasks, files, or folders:

```powershell
.\tools\local-ops.ps1 -Action Install -DryRun
```

Use `-RemoveData` with uninstall only when local app data should be removed too:

```powershell
.\tools\local-ops.ps1 -Action Uninstall -RemoveData
```

## Machine Scope Dry Run

The same script now exposes the future installer-managed service surface through `-Scope Machine`. This mode is intentionally dry-run for write operations until the signed installer owns elevation, service identity, rollback, and code-signing policy.

```powershell
.\tools\local-ops.ps1 -Action Status -Scope Machine
.\tools\local-ops.ps1 -Action Install -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Repair -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Uninstall -Scope Machine -DryRun
```

Machine-scope dry runs report:

- target install root under `%ProgramFiles%\SamhainSecurity`;
- Windows service name `SamhainSecurityService`;
- planned service command, start mode, recovery policy, and status verification;
- whether the current PowerShell process is elevated;
- whether existing service registration is present.

Running `Install`, `Repair`, or `Uninstall` with `-Scope Machine` and without `-DryRun` fails fast by design in this build.

## Storage

- Install root: `%LOCALAPPDATA%\SamhainSecurity`
- Service data: `%APPDATA%\SamhainSecurity`
- Operation state: `%LOCALAPPDATA%\SamhainSecurity\install-state.json`
- Migration backups: `%APPDATA%\SamhainSecurity\migration`

The local operations script only writes under `%LOCALAPPDATA%` and `%APPDATA%`. Cleanup refuses paths outside those roots.

## Integrations

- Current-user startup: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- Link handler: `HKCU\Software\Classes\samhain`
- User service task: `Samhain Security Service`

The task starts `service\samhain-service.exe run` at logon. The future signed installer will replace this with a privileged service identity.

## Migration

Install backs up recognized older local state folders into `%APPDATA%\SamhainSecurity\migration`. The backup is conservative: it preserves files for review and does not activate older configs automatically.

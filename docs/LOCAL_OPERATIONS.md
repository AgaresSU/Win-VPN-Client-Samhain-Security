# Local Operations

Version: `1.2.5`

The Windows package includes `tools\local-ops.ps1` for current-user install, repair, uninstall, status checks, and the first installer-owned machine service path.

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

Use `-Scope Machine` for the machine service path. `Status` is read-only and works from a normal shell. `Install`, `Repair`, and `Uninstall` can be inspected with `-DryRun` from any shell, and real write operations require an elevated PowerShell session.

```powershell
.\tools\local-ops.ps1 -Action Status -Scope Machine
.\tools\local-ops.ps1 -Action Install -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Repair -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Uninstall -Scope Machine -DryRun
```

Run real machine operations from an elevated PowerShell session:

```powershell
.\tools\local-ops.ps1 -Action Install -Scope Machine
.\tools\local-ops.ps1 -Action Repair -Scope Machine
.\tools\local-ops.ps1 -Action Uninstall -Scope Machine
```

Machine-scope dry runs report:

- target install root under `%ProgramFiles%\SamhainSecurity`;
- machine data root under `%ProgramData%\SamhainSecurity`;
- Windows service name `SamhainSecurityService`;
- planned service command, start mode, recovery policy, and status verification;
- whether the current PowerShell process is elevated;
- whether existing service registration is present.

Running `Install`, `Repair`, or `Uninstall` with `-Scope Machine` from a non-elevated shell fails before files, services, firewall, routing, or data roots are modified.

## Storage

- Install root: `%LOCALAPPDATA%\SamhainSecurity`
- Current-user service data: `%APPDATA%\SamhainSecurity`
- Machine service data: `%ProgramData%\SamhainSecurity`
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

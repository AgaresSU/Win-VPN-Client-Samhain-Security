# Local Operations

Version: `1.4.1`

The Windows package includes `tools\local-ops.ps1` for current-user install, repair, rollback, uninstall, status checks, and the first installer-owned machine service path.

## Commands

Run these commands from the extracted package root:

```powershell
.\tools\local-ops.ps1 -Action Install
.\tools\local-ops.ps1 -Action Repair
.\tools\local-ops.ps1 -Action Rollback
.\tools\local-ops.ps1 -Action Status
.\tools\local-ops.ps1 -Action Uninstall
```

Use `-DryRun` to inspect actions without writing registry keys, tasks, files, or folders:

```powershell
.\tools\local-ops.ps1 -Action Install -DryRun
.\tools\local-ops.ps1 -Action Rollback -DryRun
```

Use `-RemoveData` with uninstall only when local app data should be removed too:

```powershell
.\tools\local-ops.ps1 -Action Uninstall -RemoveData
```

## Machine Scope Dry Run

Use `-Scope Machine` for the machine service path. `Status` is read-only and works from a normal shell. `Install`, `Repair`, `Rollback`, and `Uninstall` can be inspected with `-DryRun` from any shell, and real write operations require an elevated PowerShell session.

```powershell
.\tools\local-ops.ps1 -Action Status -Scope Machine
.\tools\local-ops.ps1 -Action Install -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Repair -Scope Machine -DryRun
.\tools\local-ops.ps1 -Action Rollback -Scope Machine -DryRun
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
- Rollback state: `%APPDATA%\SamhainSecurity\rollback\rollback-state.json`
- Previous package slot: `%APPDATA%\SamhainSecurity\rollback\previous-package`
- Migration backups: `%APPDATA%\SamhainSecurity\migration`

The local operations script only writes under `%LOCALAPPDATA%` and `%APPDATA%`. Cleanup and rollback refuse paths outside those roots.

## Rollback

Current-user `Install` and `Repair` preserve the previous package before replacing files. `Rollback` stops package-owned processes, restores the preserved package slot, reapplies startup and link ownership, rewrites desktop integration evidence, registers the user service task, and starts the local service again.

The rollback slot is not a backup system for user data. Subscription state and diagnostics stay in `%APPDATA%\SamhainSecurity`; package rollback only restores executable, tools, docs, assets, manifests, and install evidence from the previous installed package.

## Integrations

- Current-user startup: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- Link handler: `HKCU\Software\Classes\samhain`
- User service task: `Samhain Security Service`
- Ownership evidence: `%LOCALAPPDATA%\SamhainSecurity\desktop-integration.json`

The task starts `service\samhain-service.exe run` at logon. Current-user install and repair write the expected startup command, expected `samhain://` command, actual registry values, ownership booleans, and drift status to `desktop-integration.json`. `Status` reports the same object, so stale handlers from older packages are visible before repair.

Machine scope intentionally reports desktop integration as `per-user`; the privileged service path owns the service, while startup, tray, and link handoff remain user-facing desktop integration.

## Migration

Install backs up recognized older local state folders into `%APPDATA%\SamhainSecurity\migration`. The backup is conservative: it preserves files for review and does not activate older configs automatically.

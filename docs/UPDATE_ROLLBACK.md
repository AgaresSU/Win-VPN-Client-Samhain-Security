# Update And Rollback

Version: `1.4.5`

Samhain Security stable packages use a sibling update manifest and archive. The manifest must declare the stable channel, target runtime, archive size, archive SHA256, package validation scripts, signing status, and update policy.

## Update Policy

- Archive integrity uses SHA256 and must match the update manifest before extraction.
- Downgrades are blocked by default when the verifier is given the currently installed version.
- Intentional recovery downgrades require `-AllowDowngradeRecovery`.
- The minimum supported update baseline is recorded in the manifest.
- Release evidence records the update policy and rollback policy used by the package.

## Rollback Slot

Current-user `Install` and `Repair` preserve the previous installed package before copying the new package. The preserved package lives at:

```text
%APPDATA%\SamhainSecurity\rollback\previous-package
```

Rollback metadata is written to:

```text
%APPDATA%\SamhainSecurity\rollback\rollback-state.json
```

The rollback slot stores executable package content, tools, docs, assets, manifests, checksums, and install evidence. It does not overwrite subscription data, diagnostics, or service-owned runtime state.

## Operator Commands

```powershell
.\tools\local-ops.ps1 -Action Status
.\tools\local-ops.ps1 -Action Rollback -DryRun
.\tools\local-ops.ps1 -Action Rollback
```

Use recovery downgrade only when intentionally backing out a bad release:

```powershell
.\tools\verify-update-manifest.ps1 -ExpectedVersion 1.4.5 -RequireStableChannel -InstalledVersion 9.9.9 -AllowDowngradeRecovery
```

Normal release verification should omit `-AllowDowngradeRecovery` so accidental downgrades fail.

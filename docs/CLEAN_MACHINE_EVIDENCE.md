# Clean Machine Evidence

Version: `1.4.0`

This checklist records repeatable evidence from a fresh Windows profile or test machine without changing the simple desktop workflow.

## Automated Evidence

Run from the extracted package root or from the repository:

```powershell
.\tools\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.0
```

For local release verification without launching the desktop:

```powershell
.\scripts\write-clean-machine-evidence.ps1 -ExpectedVersion 1.4.0 -SkipLaunch
```

The script records:

- Windows version and build;
- current user and admin role;
- package validation;
- stable update-manifest verification when the sibling archive and manifest are present;
- signing readiness inventory;
- generated release notes;
- current-user install, repair, rollback, and uninstall dry-runs;
- update downgrade guard and explicit recovery override checks;
- desktop integration ownership for autostart, `samhain://`, tray ownership, and single-instance handoff;
- machine-scope service status plus install, repair, rollback, and uninstall dry-runs;
- non-elevated machine writes fail before modifying system locations;
- service status, self-check command, recovery policy, protection transaction snapshots, and readiness gates;
- optional desktop launch smoke.

The output file is:

```text
SamhainSecurityNative-<version>-win-x64.clean-machine-evidence.json
```

## Matrix Targets

- Windows 10, current user.
- Windows 10, administrator.
- Windows 11, current user.
- Windows 11, administrator.
- Restricted user with no unexpected privileged prompts.
- Reboot recovery after current-user startup registration.

## Acceptance

Each matrix target should keep the generated JSON with the matching package archive hash and release tag. Any failed step must be fixed or documented before publishing a public installer.

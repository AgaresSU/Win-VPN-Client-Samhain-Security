# Samhain Security Installer Skeleton

This directory is the production installer handoff skeleton for the Windows package.

The portable package remains usable for internal validation, but public updater publishing is blocked until this installer path is completed, production-signed, and rehearsed on a clean Windows machine.

## Ownership Boundary

The package owns:

- release manifest verification;
- archive hash and size verification;
- local update rehearsal;
- current-user fallback operations;
- release evidence output.

The signed installer owns:

- production signing;
- elevation;
- Program Files install;
- service registration;
- update apply;
- machine rollback.

## Files

- `SamhainSecurityInstaller.wxs`: WiX project skeleton for the future per-machine installer.
- `installer-build-plan.json`: local toolchain and unsigned MSI dry-run contract.
- `signing-policy.json`: production signing policy scaffold with expected certificate inputs and signing targets.
- `installer-handoff.json`: machine-scope handoff contract consumed by package gates.

## Release Rule

`tools\test-installer-skeleton.ps1` must pass before a stable package can be promoted. The gate proves that the installer contract exists and that public publishing remains blocked until production signing is supplied.

`tools\test-installer-toolchain.ps1` must also pass. When a supported WiX 6.x command is available, it builds a temporary unsigned MSI and verifies the artifact. If WiX is not installed, the gate records a plan-only preflight and keeps public publishing blocked.

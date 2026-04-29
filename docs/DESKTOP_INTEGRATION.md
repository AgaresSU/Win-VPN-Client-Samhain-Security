# Desktop Integration

Version: `1.4.0`

Desktop integration is owned by the current-user package operation and the desktop app. The privileged machine service does not silently take over user-facing startup, tray, or link behavior.

## Owned Surfaces

- Autostart: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `Samhain Security`.
- Link handler: `HKCU\Software\Classes\samhain`.
- Tray behavior: desktop app.
- Single-instance handoff: desktop app local handoff channel.

## Evidence

`tools\local-ops.ps1 -Action Status` reports a `desktopIntegration` object with:

- expected autostart command;
- expected `samhain://` command;
- expected icon path;
- actual registry values;
- ownership booleans;
- drift status;
- evidence lines for autostart, link handler, tray, and handoff ownership.

Install and repair write the same object to `%LOCALAPPDATA%\SamhainSecurity\desktop-integration.json`. If an older package still owns `samhain://`, status reports `drift` until repair rewrites the handler.

## Machine Scope

Machine-scope operations own the Windows service only. They report `desktopIntegrationPolicy = per-user` so package evidence remains honest about which layer owns user-facing integrations.

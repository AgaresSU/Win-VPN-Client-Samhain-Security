# Daily UX Freeze

Version: `1.3.0`

The primary Samhain Security screen is frozen around one normal flow:

1. Add or paste a subscription.
2. Open a subscription group.
3. Pick a server.
4. Connect or disconnect.
5. Read status, latency, route mode, and traffic without opening technical panels.

## Daily Surface

- Left navigation stays short: add, servers, settings, statistics, logs, about.
- The server page shows search, refresh, subscription actions, grouped server rows, paste, and add.
- The right status panel shows connection state, power control, selected server, latency test, route chips, and traffic.
- Technical engine controls, restore buttons, raw config previews, and policy diagnostics stay inside `Расширенные настройки`.

## Visual Rules

- No native bright hover backgrounds on buttons, menus, dialogs, or list actions.
- Buttons use the dark red graphite palette with restrained borders.
- Small action icons are custom line icons or packaged action glyphs, not ad hoc text symbols.
- Country flags are oval rendered badges without extra circular overlays.
- Russian text must elide rather than overlap in compact windows.

## QA Checklist

- Main window at `1360x880`: no visible text overlap.
- Minimum window at `980x700`: server rows, right panel, and navigation remain usable.
- Menu actions keep consistent icon weight and do not flash light native backgrounds.
- Add and rename dialogs keep dark backgrounds and custom buttons.
- Settings page keeps advanced controls behind one explicit expansion point.

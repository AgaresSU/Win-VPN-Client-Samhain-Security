# UX Principles

## Main Rule

The daily client must stay simple:

```text
paste subscription -> choose server -> connect
```

No ranking controls, no visible protocol editor, no technical filter blocks on the main screen.

## Main Screen

- Subscription group header.
- Search field.
- Compact server rows.
- Ping value in each row.
- Big connection control.
- Small speed and traffic summary.
- Detailed logs and diagnostics stay off the main screen.

## Add Flow

- `Ctrl+V` recognizes a subscription-like URL from the clipboard.
- `+` opens a small add dialog with name and URL.
- The subscription owns mixed protocols in one compact server group.

## Settings

Visible:

- route mode;
- selected applications entry point;
- autostart later;
- language/theme later.

Hidden in advanced settings:

- engine paths;
- raw configs;
- DNS;
- ports;
- firewall;
- WFP;
- logs internals;
- diagnostic export.

## Diagnostics

The logs page can refresh service logs, filter by category, and export a redacted support folder. The export action copies the folder path to the clipboard after creation.

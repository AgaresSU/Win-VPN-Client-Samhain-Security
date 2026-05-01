# Visual QA

Version: `1.5.1`

The target style is dark red, graphite, compact, and calm. The UI can be inspired by clean commercial clients, but branding, artwork, and icon shapes must remain Samhain Security's own.

## Main Shell

- Navigation stays compact and readable at narrow and wide widths.
- Active navigation uses the red graphite accent without native light-blue hover or focus bleed.
- Icons are simple white line glyphs; settings uses a gear, servers uses a globe, statistics uses a chart pulse, logs uses a document/rotation mark, add uses plus.
- Text never overlaps icons, badges, or window chrome.
- The app icon renders in the title bar, tray, and sidebar without a white background plate.

## Server List

- Subscription rows are grouped and expandable.
- Secondary actions stay in the quiet menu: refresh, ping test, pin, copy URL, edit, delete.
- Country badges are oval or circular only when intentionally clipped by the badge frame, with no stray outline circles.
- Selected rows use a muted graphite-red fill, not a bright light fill.
- Missing latency is shown as `n/a`; measured latency uses `ms`.

## Connection Panel

- The power control is a flat circular control with one outer ring and a clear glyph.
- Connected state uses the dark green accent for the glyph, status badge, and ring.
- Waiting/disconnected state uses the red accent without harsh glow.
- Proxy and TUN route buttons are real controls and show selected state without native highlight bleed.
- Traffic cards stay dark and readable.

## Dialogs And Menus

- Add-subscription dialog uses dark buttons and fields that match the shell.
- Technical options stay behind advanced settings.
- Menus use readable action icons: refresh, speedometer, pin, clipboard, sliders, trash.
- Destructive actions use a muted red accent only on the icon/text, not a bright background.

## QA Viewports

- 360 x 740 compact sidebar and connection panel.
- 900 x 700 desktop shell.
- 1280 x 720 split server list and connection panel.
- 1600 x 900 full-width shell.

## Release Blockers

- Any native light-blue button highlight in normal use.
- White panels in the dark shell.
- Text clipped by its parent button or row.
- Missing country badge for a known country code.
- Fake latency, fake connected state, or hidden service failure.

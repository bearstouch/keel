# Design sources

This folder holds a saved copy of the **Keel — Native calm** design canvas, the reference for [Design](index.md).

## App canvas

- Live canvas: <https://claude.ai/artifact/LK7fzDX2G7yKKGo8twVnWp> (private to its owner until shared).
- `canvas/canvas.json` is the canvas index: board names, positions and titles.
- `canvas/*.dc.html` are the boards. Each is a Design Component: HTML markup with `{{…}}` holes that the small
  `Component` class at the bottom of the file fills in. The `renderVals()` function holds each screen's theme tokens
  and sample data. The files need the canvas runtime (`support.js`) to render, so view them in the live canvas. The
  saved copies are for reading exact colors, sizes and copy.
- Light boards take a `theme` prop. The `*Dark.dc.html` boards are thin wrappers that render the same screen with
  `theme="dark"` (and `production`, `stage` or `tab` where relevant). `Sidebar.dc.html` is shared by the other screens.

| Board | Screen |
| --- | --- |
| `Main` / `BrowserDark` | Window, sidebar, toolbar, tabs, key list and editor |
| `Sidebar` | Connections sidebar (shared) |
| `Connection` / `ConnectionDark` | New Connection sheet |
| `Console` / `ConsoleDark` | Console mode |
| `Info` / `InfoDark` | Server info overview |
| `BulkDelete` / `BulkDeleteDark` | Bulk delete sheet with typed confirmation |
| `Tokens` | Palette and type tokens |

## App icon canvas

`icon/` holds the app icon canvas (<https://claude.ai/artifact/XPgiQ6JeBgonxQpCzTESsa>). `Icon.dc.html` is the icon
itself, with `variant` (red, dark, tinted, light), `concept` (`layers` is the chosen concept A) and `size` props. The
other boards show concepts, sizes, appearances and lockups. The shipped SVG is `release/icon/keel-icon.svg`, and
`scripts/generate-app-icon.sh` builds every asset from it.

## Changing the design

Update the canvas, copy its files here again, and update [Design](index.md) in the same change. If a color table
changed, regenerate the token fixture with `python3 -I scripts/generate-design-tokens.py`.

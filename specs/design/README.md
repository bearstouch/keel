# Design sources

A saved copy of the **Keel — Native calm** design canvas, taken as the reference for [08 Design](../08-design.md).

- Live canvas: <https://claude.ai/artifact/LK7fzDX2G7yKKGo8twVnWp> (private to its owner until shared).
- `canvas/canvas.json` is the canvas index: board names, positions, titles.
- `canvas/*.dc.html` are the boards. Each is a Design Component: HTML markup with `{{…}}` holes filled by the small `Component` class at the bottom of the file. The `renderVals()` function holds each screen's theme tokens and sample data. The files need the canvas runtime (`support.js`) to render, so open the live canvas to view them; read them here for exact colors, sizes and copy.
- Light boards take a `theme` prop; the `*Dark.dc.html` boards are thin wrappers that render the same screen with `theme="dark"` (and `production`, `stage` or `tab` where relevant). `Sidebar.dc.html` is shared by the other screens.

`icon/` holds the app icon canvas (<https://claude.ai/artifact/XPgiQ6JeBgonxQpCzTESsa>): `Icon.dc.html` is the icon itself, with `variant` (red, dark, tinted, light), `concept` (layers = the chosen concept A) and `size` props; the other boards show concepts, sizes, appearances and lockups.

When the design changes: update the canvas, copy its files here again, and update 08 Design in the same change.

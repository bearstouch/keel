# 08 Design

Keel's visual contract. The reference is the **Keel — Native calm** design canvas; its sources are saved in [`design/`](design/) and the live canvas is at <https://claude.ai/artifact/LK7fzDX2G7yKKGo8twVnWp> (private to the owner unless shared). When code and this page disagree, this page wins; when the design changes, update the canvas, the saved sources and this page together.

## Principles

| ID | Rule |
| --- | --- |
| DS-01 | **Show less, reveal on demand** ([NFR-UX05](04-non-functional-requirements.md#usability)). One toolbar row, one-line sidebar rows, one metadata line per key, secondary actions in `⋯`, Save only when something changed, TLS / SSH / Advanced collapsed, full INFO behind "Show all". |
| DS-02 | **Redis red is the brand.** The accent is used only for the primary action, selection, focus, links, switches, the active tab cue and the Keel mark. It is never used to mean "warning". |
| DS-03 | **Production is maroon, not accent red.** The production strip uses a deep maroon that differs from the accent in lightness, and always carries text. Destructive buttons use the danger color and always sit behind a typed confirmation. |
| DS-04 | **Color is never the only signal.** Type badges have text, labels have names (VoiceOver and tooltip), status has words ("TLS not verified" beside the connection name in the toolbar, with an open lock on the tab). Contrast ≥ 4.5:1 for text and ≥ 3:1 for badges and the strip (NFR-AX04). Focus is always visible (NFR-AX02): views that draw their own selection show a 2 pt `accent` focus ring. |
| DS-05 | **The console is always dark** (`#151719`, Trellis's terminal background), in both themes. |
| DS-06 | Only the tokens below are used; new colors are added here first. |

## Color

Every row names the code token (`KeelTheme`) beside its value; a row with two names and one value gives both names that value. `scripts/generate-design-tokens.py` reads these tables into `Tests/Fixtures/Design/tokens.json`, and `ThemeTokensTests` fails when the code and this page disagree.

### Light (first-launch default)

| Token | Value | Use |
| --- | --- | --- |
| `bg` / `sheet` | `#FFFFFF` | Content, editor, active tab / sheets, Settings, command palette |
| `sidebar` | `#FBEEEC` | Sidebar (soft Redis-red tint) |
| `sidebarSelection` | `#F4D2CD` | Selected connection |
| `sidebarHair` | `#F1DAD7` | Sidebar edge |
| `tabBar` / `codeBg` | `#F6F8FB` | Tab bar, value viewer |
| `field` / `soft` | `#F1F4F8` | Inputs, filter, db picker, secondary buttons |
| `segBg` | `#E7ECF2` | Viewer switch track |
| `segOn` | `#FFFFFF` | Selected segment |
| `segShadow` | `rgba(24,33,47,0.12)` | Selected segment's lift |
| `card` | `#F4F7FA` | Info tiles |
| `track` | `#DDE4EC` | Info memory bar track |
| `hair` / `hairSoft` | `#E3E8EE` / `#EEF2F6` | Separators / table rows |
| `fg` / `muted` | `#18212F` / `#4E5B6D` | Text / secondary text |
| `accent` / `onAccent` | `#C7302A` / `#FFFFFF` | Redis red (darkened from `#DC382D` for text contrast) |
| `selection` | `#FCEAE8` | Selected key, field, label chip |
| `changedRow` | `#FDF3F2` | Row with an unsaved edit |
| `saveBar` / `onSaveBar` | `#18212F` / `#FFFFFF` | Floating unsaved-changes bar / its text |
| `success` / `warning` / `danger` | `#216B3B` / `#805400` / `#B22D32` | Status words, destructive actions |
| `prodStrip` / `onProdStrip` | `#7A1A14` / `#FFFFFF` | Production strip / its text |
| `scrim` | `rgba(24,33,47,0.22)` | Behind sheets |

### Dark (Trellis native graphite + Redis red)

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `#1E1E1E` | Content, editor, active tab |
| `sidebar` / `tabBar` | `#29292B` | Sidebar, tab bar |
| `sidebarSelection` / `selection` | `#3D2826` | Selected connection, key, field |
| `sidebarHair` | `#333335` | Sidebar edge |
| `sheet` | `#2A2A2C` | Sheets, Settings, command palette |
| `card` / `codeBg` | `#262628` | Info tiles, value viewer |
| `field` / `segBg` | `#38383A` | Inputs in sheets, viewer switch track |
| `soft` | `#2C2C2E` | Filter, db picker |
| `segOn` / `track` | `#48484A` | Selected segment, Info memory bar track |
| `segShadow` | `rgba(0,0,0,0)` | None: the segment isn't lifted in dark |
| `hair` / `hairSoft` | `#38383A` / `#2C2C2E` | Separators / table rows |
| `fg` / `muted` | `#E5E5E7` / `#A1A1A6` | Text / secondary text |
| `accent` / `onAccent` | `#FF6F61` / `#2A0B08` | Redis red for dark backgrounds |
| `changedRow` | `#2E2423` | Row with an unsaved edit |
| `saveBar` / `onSaveBar` | `#E5E5E7` / `#1E1E1E` | Floating unsaved-changes bar / its text |
| `success` / `warning` / `danger` | `#8DDAA4` / `#F2CC7A` / `#FFA4A4` | Status words, destructive actions |
| `prodStrip` / `onProdStrip` | `#4A1F1C` / `#FFD6D1` | Production strip / its text |
| `scrim` | `rgba(5,7,10,0.55)` | Behind sheets |

### Increase Contrast

With **Increase Contrast** on (System Settings → Accessibility → Display), these tokens replace their values in the theme shown; every other token keeps its value. Secondary text gains contrast and hairlines reach 3:1 against the surface they divide.

| Token | Light | Dark |
| --- | --- | --- |
| `muted` | `#364152` | `#C7C7CC` |
| `hair` | `#7D8796` | `#7C7C80` |
| `hairSoft` | `#8A94A3` | `#6E6E73` |
| `sidebarHair` | `#A67A74` | `#7C7C80` |

### Console (both themes)

| Token | Value | Use |
| --- | --- | --- |
| `background` | `#151719` | Background |
| `output` / `command` | `#DEE0E5` / `#FFFFFF` | Output / the typed command |
| `prompt` | `#7C899C` | Prompt (`127.0.0.1:6379[3]>`; the canvas abbreviates it as `›`) |
| `hint` | `#768297` | Inline argument hint (dimmer than the prompt, still 4.5:1) |
| `notice` | `#7C899C` | Keel notices ("Not sent.", "Stopped.") |
| `null` | `#8C95A3` | `(nil)` |
| `error` | `#FFA4A4` | `(error)` |
| `cursor` | `#FF8A7E` | Cursor |
| `list` / `listSelected` | `#2A2A2C` / `#3D2826` | Completion list / selected name |
| `listBorder` | `#3A3A3C` | Completion list and Stop button border |

ANSI (not used by v1 output, kept for reference): Trellis default `#1B202A #EF8585 #8DDAA4 #F2CC7A #8BB8F0 #C6A0E8 #7FD5DD #CFD7E2` + brights.

### Type badges and labels

| Badge | Light text / fill | Dark text / fill |
| --- | --- | --- |
| STR | `#185AA8` / `#E3EDF9` | `#8BB8F0` / `#1E2B3E` |
| HASH | `#6B3FA0` / `#EFE7F8` | `#C6A0E8` / `#2A2238` |
| LIST | `#0F6A6E` / `#DDF1F1` | `#7FD5DD` / `#163034` |
| SET | `#216B3B` / `#E2F2E7` | `#8DDAA4` / `#183025` |
| ZSET | `#805400` / `#F8EDD8` | `#F2CC7A` / `#342B19` |
| STREAM | `#A02D6A` / `#F8E4EF` | `#F5A3CF` / `#36202E` |
| OTHER | `muted` / `soft` | `muted` / `soft` |

Badges distinguish types, not brand, so they keep their own hues. JSON syntax in the viewer:

| Syntax | Light | Dark |
| --- | --- | --- |
| `jsonKey` | `#185AA8` | `#8BB8F0` |
| `jsonString` | `#216B3B` | `#8DDAA4` |
| `jsonLiteral` (numbers, `true`, `false`, `null`) | `#805400` | `#F2CC7A` |

| Label | Light | Dark |
| --- | --- | --- |
| Production (`red`) | `#C8363C` | `#FF7B7B` |
| Staging (`orange`) | `#B86200` | `#F2A65A` |
| Yellow (`yellow`) | `#8A6D00` | `#F2D36B` |
| Local (`green`) | `#2E8B4F` | `#8DDAA4` |
| Blue (`blue`) | `#2F6FBF` | `#8BB8F0` |
| Purple (`purple`) | `#7B4FB0` | `#C6A0E8` |
| Gray (`gray`) | `#7A8596` | `#8E8E93` |

Every FR-CN02 color has a dot; **None** is an empty `muted` ring. The New Connection sheet shows all eight dots, selected one ringed in `accent`, and the selected label's name beside them.

### Contrast pairs

`ThemeContrastTests` checks every pair below in light, dark and both Increase Contrast variants (NFR-AX04, WCAG 2 ratio):

| Pair | Minimum |
| --- | --- |
| `fg` on every surface: `bg`, `sheet`, `sidebar`, `sidebarSelection`, `tabBar`, `codeBg`, `field`, `soft`, `segBg`, `segOn`, `card`, `selection`, `changedRow` | 4.5:1 |
| `muted` on every surface but `segOn` (a selected segment's text is `fg`) | 4.5:1 |
| `accent`, `success`, `warning`, `danger` on `bg`, `sheet`, `sidebar`, `tabBar`, `codeBg`, `soft`, `card`, `selection`, `changedRow` | 4.5:1 |
| `onAccent` on `accent`, `onSaveBar` on `saveBar`, `onProdStrip` on `prodStrip` | 4.5:1 |
| Badge text on its fill; JSON syntax on `codeBg` | 4.5:1 |
| Console `output`, `command`, `prompt`, `hint`, `notice`, `null`, `error` on `background`; `command` on `list` and `listSelected` | 4.5:1 |
| `prodStrip` against `tabBar` (light; dark relies on the strip's text, FR-SF02) | 3:1 |
| Console `cursor` on `background`; label dots on `sidebar` and `bg` | 3:1 |
| With Increase Contrast: `hair`, `hairSoft` on `bg`, `sidebarHair` on `sidebar` | 3:1 |

### Theme and motion

| ID | Rule |
| --- | --- |
| DS-11 | **Theme** (FR-AP04): Light (first-launch default), Dark or System, chosen in View → Theme and saved in `settings.json`. A change applies at once to every window, sheet and the console chrome without reconnecting or reloading anything; System follows the macOS appearance live. |
| DS-12 | **Increase Contrast** swaps in the table above at once, in any theme; macOS's own high-contrast controls come with it. |
| DS-13 | **Reduce Motion**: Keel draws no decorative motion. Any animation goes through `Tokens.animation`, which gives none while Reduce Motion is on. Text that changes with time (a TTL counting down, Info's auto-refresh) is content, not motion, and keeps updating. |

## Typography

| Role | Font | Size / weight |
| --- | --- | --- |
| Interface text | Inter | 13 / 400 |
| Connection name (toolbar) | Inter | 14 / 600 |
| Sheet title | Inter | 18 / 600 |
| Section heading | Inter | 14 / 600 |
| Labels, metadata | Inter | 12–12.5 / 400, `muted` |
| Group heading (sidebar) | Inter | 11 / 400, `muted` |
| Info tile value | Inter | 30 / 600, tracking −0.02em |
| Badges | Inter | 9.5–10 / 600, tracking 0.04em, uppercase |
| Key names, values, hosts, patterns | JetBrains Mono | 12.5 / 400 |
| Editor key title | JetBrains Mono | 20 / 600 |
| Console | JetBrains Mono | 14, line height 1.7 |

Both fonts are bundled and registered for the Keel process only ([MAC-19](07-macos-support.md#input-and-text)): Inter Regular (400), Medium (500) and SemiBold (600; heavier weights use it too), and JetBrains Mono Regular, Bold (used for 600), Italic and Bold Italic. A face that fails to load falls back to the system font (or the system monospace font) with no loss of function. Every SwiftUI root sets Inter 13 as the default, so text without an explicit role is still Inter.

## Layout and shape

| Element | Size |
| --- | --- |
| Reference window | 1440 × 900 |
| Sidebar | 232 wide |
| Toolbar | 52 high |
| Tab bar / tab | 38 high / 31 high, radius 8 8 0 0 |
| Production strip | 28 high |
| Key list | 380 wide; rows 32 high, radius 7; indent 18 per level |
| Editor | padding 28 × 36; field rows 40 high |
| Sheets | New Connection 560, confirmations 480; radius 14; padding 28 × 32 |
| Controls | height 30–36, radius 7–8; badges radius 4; Info tiles radius 12 |

## Components

### Sidebar

Traffic lights; "Connections" heading with `+`; folder groups as small muted headings; one-line rows (label dot, name, link icon when connected); the Keel app icon at 24 px (its two-bar small-size form, [App icon](#app-icon)) and the "Keel" wordmark (Inter 13.5 / 600) at the bottom left.

Profiles outside any folder come first, without a heading; folders follow in their saved order, an empty folder keeps its heading as a drop target. Clicking a heading collapses it, and a collapsed heading adds a small `muted` chevron (an expanded one shows none). Rows are 32 high, radius 7; the selected row is `sidebarSelection` with the name at 600. A profile without a label shows the empty `muted` ring; a failed one shows "Failed" in `danger`. Secondary actions live in the context menu (Connect, Connect in New Tab, Edit, Rename, Duplicate, Copy URL, Move To, Delete); dragging a row onto another row places it before that row, onto a heading at the end of that folder, onto "Connections" at the top level.

### Toolbar

Connection name, db picker (`db0 ▾` in mono on `soft`, a menu listing "db3 · 1,204 keys" for databases with keys and the name alone for empty ones; ⌥⌘0–9), centered **Browser | Console | Info** switch, search icon (⌘K). Info adds the server version beside the name and a refresh button.

### Tab bar

Under the toolbar, 38 high on `tabBar`: one 31 px tab per open connection (7 px label dot, name, `×`), `+` for a new tab (a popover listing the saved connections). The active tab uses `bg` at 600 with a hairline border, radius 8 8 0 0, and covers the bar's bottom hairline so it joins the content; others are flat `muted` text. The context menu holds Connect / Reconnect, Disconnect, Move to New Window and Close Tab. A tab that isn't connected shows its name and "Disconnected · Connect" centered (a failure: "Failed" in `danger`, the message and its suggestion, **Try Again**); connecting shows a small spinner and "Connecting to <name>…". The mode switch is a `soft` track with the selected segment on `segOn` (white in light, `#48484A` in dark).

### Production strip

Under the tab bar, only for production connections: centered "Production · Read-only" on `prodStrip` (Inter 12 semibold in the strip's text color; "Production" alone while writes are allowed), full width and 28 high. It follows the window's selected tab. The first write in a writable production tab adds one 34 px `soft` line above the editor: a `warning` triangle, "Writing to PRODUCTION" (semibold), "Changes here reach the production server." in `muted` and a trailing ×. A session the server refuses writes to shows a muted lock and "Server-enforced read-only" in the toolbar after the database picker.

### Key list

Filter field (glob pattern) on `soft`: the magnifier is a menu that switches the field between **Server pattern** (applied on Return) and **Loaded keys** (live substring); then a `?` that opens the glob help popover (pattern mode) and a quiet type menu ("All types", the six core types, "Other (module types)"). A client-side type filter adds one muted line under the field saying so. ⌘F focuses the field; 32 px tree rows (18 px indent per level) with chevron, name, child count (folders) or short TTL (only for expiring keys) and a 40 px type badge (none until the type is loaded); the selected row is a 7 px rounded `selection` fill with unchanged text; footer "250,000 of 1.2M keys loaded · Load more" with a trailing borderless `⋯` menu (Show Sizes). With sizes on, a key's muted text reads "1m 30s · 4.1 KB". A key opened after it was deleted elsewhere adds one `soft` line above the footer: a `warning` triangle, "Key no longer exists" and a **Remove from List** link in `accent` (the words carry the meaning).

### Editor

Key title (mono) + type badge + `⋯`; one metadata line; field table (Field / Value) with the selected row in `selection` and changed rows marked by an accent dot; "+ Add field"; **value viewer** on `codeBg` with the element name, "✓ Valid JSON" and a **Text / JSON / Hex / Raw** switch; floating save bar only with unsaved changes. Read-only: lock + "Read-only" in the metadata line, no add/save.

### Command palette

A 560 px card on `sheet`, 64 px from the window's top, with a hairline border and a soft shadow: a 44 px search field (Inter 15, magnifier icon) over up to eight 36 px rows. A row is the title (Inter 13; JetBrains Mono for key names), the muted subtitle, then at the right the muted shortcut and kind ("Connection", "Tab", "Recent key", "Database", "Command", "Settings"). The highlighted row is on `selection`; nothing else is colored. Settings → Keyboard is a grouped list (one section per menu, then "Can't be changed" with lock icons) with the rejection message in `danger` beside an icon above **Restore Defaults**.

### Sheets and cards

New Connection, typed confirmation (bulk delete, FLUSHDB, multi-key delete), bulk-delete progress. Each has a title, at most one sentence of explanation, the minimum fields, and two or three buttons with the primary on the right. The destructive button stays disabled until the typed text matches.

## App icon

The icon is **concept A, Layered keel**: three rounded bars that narrow downward (data layers forming a hull) above a tapered fin with a bulb (a racing keel), in white on a Redis-red macOS squircle. Reference canvas: <https://claude.ai/artifact/XPgiQ6JeBgonxQpCzTESsa>; sources in [`design/icon/`](design/icon/) (`Icon.dc.html` holds the exact geometry, in a 1024 grid with the 824 squircle at 100,100, corner radius 186).

| ID | Rule |
| --- | --- |
| DS-07 | Default icon: background gradient `#EA4A3E` → `#B3271E`, white mark (`#FFFFFF` → `#FCE7E4`), soft top shine and a `#5E120D` shadow at 28% under the mark. |
| DS-08 | At 48 px and below the mark switches to its small form: two bars, fin and bulb, no shadow. The sidebar uses the small form at 24 px. |
| DS-09 | Appearances: **Default** (red), **Dark** (graphite `#3A3A3C` → `#161617`, red mark), **Tinted** (graphite, light-gray mark for system tinting), **Light** (white → `#F3EDEC`, red mark; DMG background, website, documents). |
| DS-10 | Sizes shipped in the asset catalog / `.icns`: 16, 32, 64, 128, 256, 512, 1024 px (with @2x), all exported from the same source. The wordmark is "Keel" in Inter Bold, tracking −0.045em, beside the icon at roughly 0.7× the icon height. |

Concepts B (hull and keel) and C (keel monogram) are kept on the icon canvas for reference only.

## Screens

Boards in the canvas (light row and matching dark row):

| Screen | Light board | Dark board | Specs |
| --- | --- | --- | --- |
| Key browser | `Main` | `BrowserDark` (production, read-only) | FR-KB, FR-ED, FR-SF02 |
| Console | `Console` | `ConsoleDark` (production, read-only) | FR-CO |
| Server info | `Info` | `InfoDark` | FR-SI |
| New connection | `Connection` | `ConnectionDark` | FR-CN19 |
| Bulk delete | `BulkDelete` (confirm) | `BulkDeleteDark` (progress) | FR-SF03, FR-SF05 |
| Tokens | `Tokens` | — | this page |
| Sidebar component | `Sidebar` | — | FR-CN13 |

Not yet drawn (follow the same components): welcome screen, string / list / set / zset / stream editors, new-key sheet, command palette, Settings panes, error states for each connection category.

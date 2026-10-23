# 08 Design

Keel's visual contract. The reference is the **Keel — Native calm** design canvas; its sources are saved in [`design/`](design/) and the live canvas is at <https://claude.ai/artifact/LK7fzDX2G7yKKGo8twVnWp> (private to the owner unless shared). When code and this page disagree, this page wins; when the design changes, update the canvas, the saved sources and this page together.

## Principles

| ID | Rule |
| --- | --- |
| DS-01 | **Show less, reveal on demand** ([NFR-UX05](04-non-functional-requirements.md#usability)). One toolbar row, one-line sidebar rows, one metadata line per key, secondary actions in `⋯`, Save only when something changed, TLS / SSH / Advanced collapsed, full INFO behind "Show all". |
| DS-02 | **Redis red is the brand.** The accent is used only for the primary action, selection, focus, links, switches, the active tab cue and the Keel mark. It is never used to mean "warning". |
| DS-03 | **Production is maroon, not accent red.** The production strip uses a deep maroon that differs from the accent in lightness, and always carries text. Destructive buttons use the danger color and always sit behind a typed confirmation. |
| DS-04 | **Color is never the only signal.** Type badges have text, labels have names (VoiceOver and tooltip), status has words. Contrast ≥ 4.5:1 for text and ≥ 3:1 for badges and the strip (NFR-AX04). |
| DS-05 | **The console is always dark** (`#151719`, Trellis's terminal background), in both themes. |
| DS-06 | Only the tokens below are used; new colors are added here first. |

## Color

### Light (first-launch default)

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `#FFFFFF` | Content, editor, active tab |
| `sidebar` | `#FBEEEC` | Sidebar (soft Redis-red tint) |
| `sidebarSelection` | `#F4D2CD` | Selected connection |
| `sidebarHair` | `#F1DAD7` | Sidebar edge |
| `tabBar` / `codeBg` | `#F6F8FB` | Tab bar, value viewer |
| `field` / `soft` | `#F1F4F8` | Inputs, filter, db picker, secondary buttons |
| `segBg` | `#E7ECF2` | Viewer switch track |
| `card` | `#F4F7FA` | Info tiles |
| `hair` / `hairSoft` | `#E3E8EE` / `#EEF2F6` | Separators / table rows |
| `fg` / `muted` | `#18212F` / `#4E5B6D` | Text / secondary text |
| `accent` / `onAccent` | `#C7302A` / `#FFFFFF` | Redis red (darkened from `#DC382D` for text contrast) |
| `selection` | `#FCEAE8` | Selected key, field, label chip |
| `changedRow` | `#FDF3F2` | Row with an unsaved edit |
| `saveBar` | `#18212F` on `#FFFFFF` text | Floating unsaved-changes bar |
| `success` / `warning` / `danger` | `#216B3B` / `#805400` / `#B22D32` | Status words, destructive actions |
| `prodStrip` | `#7A1A14`, text `#FFFFFF` | Production strip |
| `scrim` | `rgba(24,33,47,0.22)` | Behind sheets |

### Dark (Trellis native graphite + Redis red)

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `#1E1E1E` | Content, editor, active tab |
| `sidebar` / `tabBar` | `#29292B` | Sidebar, tab bar |
| `sidebarSelection` / `selection` | `#3D2826` | Selected connection, key, field |
| `sidebarHair` | `#333335` | Sidebar edge |
| `sheet` | `#2A2A2C` | Sheets, Settings, approval card |
| `card` / `codeBg` | `#262628` | Info tiles, value viewer |
| `field` / `segBg` | `#38383A` | Inputs in sheets, viewer switch track |
| `soft` | `#2C2C2E` | Filter, db picker |
| `segOn` | `#48484A` | Selected segment |
| `hair` / `hairSoft` | `#38383A` / `#2C2C2E` | Separators / table rows |
| `fg` / `muted` | `#E5E5E7` / `#A1A1A6` | Text / secondary text |
| `accent` / `onAccent` | `#FF6F61` / `#2A0B08` | Redis red for dark backgrounds |
| `changedRow` | `#2E2423` | Row with an unsaved edit |
| `saveBar` | `#E5E5E7`, text `#1E1E1E` | Floating unsaved-changes bar |
| `success` / `warning` / `danger` | `#8DDAA4` / `#F2CC7A` / `#FFA4A4` | Status words, destructive actions |
| `prodStrip` | `#4A1F1C`, text `#FFD6D1` | Production strip |
| `scrim` | `rgba(5,7,10,0.55)` | Behind sheets |

### Console (both themes)

| Token | Value |
| --- | --- |
| Background | `#151719` |
| Output / command | `#DEE0E5` / `#FFFFFF` |
| Prompt `›` | `#7C899C` |
| `(nil)` | `#8C95A3` |
| `(error)` | `#FFA4A4` |
| Cursor | `#FF8A7E` |
| Completion list / selected | `#2A2A2C` / `#3D2826` |
| ANSI | Trellis default: `#1B202A #EF8585 #8DDAA4 #F2CC7A #8BB8F0 #C6A0E8 #7FD5DD #CFD7E2` + brights |

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

Badges distinguish types, not brand, so they keep their own hues. JSON syntax in the viewer uses keys `#185AA8`/`#8BB8F0`, strings `#216B3B`/`#8DDAA4`, literals `#805400`/`#F2CC7A`.

| Label | Light | Dark |
| --- | --- | --- |
| Production | `#C8363C` | `#FF7B7B` |
| Staging (orange) | `#B86200` | `#F2A65A` |
| Yellow | `#8A6D00` | `#F2D36B` |
| Local (green) | `#2E8B4F` | `#8DDAA4` |
| Blue | `#2F6FBF` | `#8BB8F0` |
| Purple | `#7B4FB0` | `#C6A0E8` |
| Gray | `#7A8596` | `#8E8E93` |

Every FR-CN02 color has a dot; **None** is an empty `muted` ring. The New Connection sheet shows all eight dots, selected one ringed in `accent`, and the selected label's name beside them.

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

Both fonts are bundled ([MAC-19](07-macos-support.md#input-and-text)).

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
| Sheets | New Connection 560, confirmations 480, approval card 380; radius 14; padding 28 × 32 |
| Controls | height 30–36, radius 7–8; badges radius 4; Info tiles radius 12 |

## Components

### Sidebar

Traffic lights; "Connections" heading with `+`; folder groups as small muted headings; one-line rows (label dot, name, link icon when connected); the Keel app icon at 24 px (its two-bar small-size form, [App icon](#app-icon)) and the "Keel" wordmark (Inter 13.5 / 600) at the bottom left.

Profiles outside any folder come first, without a heading; folders follow in their saved order, an empty folder keeps its heading as a drop target. Clicking a heading collapses it, and a collapsed heading adds a small `muted` chevron (an expanded one shows none). Rows are 32 high, radius 7; the selected row is `sidebarSelection` with the name at 600. A profile without a label shows the empty `muted` ring; a failed one shows "Failed" in `danger`. Secondary actions live in the context menu (Connect, Connect in New Tab, Edit, Rename, Duplicate, Copy URL, Move To, Delete); dragging a row onto another row places it before that row, onto a heading at the end of that folder, onto "Connections" at the top level.

### Toolbar

Connection name, db picker (`db0 ▾`), centered **Browser | Console | Info** switch, search icon (⌘K). Info adds the server version beside the name and a refresh button.

### Tab bar

Under the toolbar: one tab per open connection (label dot, name, `×`), `+` for a new tab. The active tab uses `bg` with a hairline border and joins the content; others are flat `muted` text.

### Production strip

Under the tab bar, only for production connections: centered "Production · Read-only" on `prodStrip`.

### Key list

Filter field (glob pattern) on `soft`: the magnifier is a menu that switches the field between **Server pattern** (applied on Return) and **Loaded keys** (live substring); then a `?` that opens the glob help popover (pattern mode) and a quiet type menu ("All types", the six core types, "Other (module types)"). A client-side type filter adds one muted line under the field saying so. ⌘F focuses the field; 32 px tree rows (18 px indent per level) with chevron, name, child count (folders) or short TTL (only for expiring keys) and a 40 px type badge (none until the type is loaded); the selected row is a 7 px rounded `selection` fill with unchanged text; footer "250,000 of 1.2M keys loaded · Load more" with a trailing borderless `⋯` menu (Show Sizes). With sizes on, a key's muted text reads "1m 30s · 4.1 KB".

### Editor

Key title (mono) + type badge + `⋯`; one metadata line; field table (Field / Value) with the selected row in `selection` and changed rows marked by an accent dot; "+ Add field"; **value viewer** on `codeBg` with the element name, "✓ Valid JSON" and a **Text / JSON / Hex / Raw** switch; floating save bar only with unsaved changes. Read-only: lock + "Read-only" in the metadata line, no add/save.

### Sheets and cards

New Connection, typed confirmation (bulk delete, FLUSHDB, multi-key delete), bulk-delete progress, approval card, Settings → Agents. Each has a title, at most one sentence of explanation, the minimum fields, and two or three buttons with the primary on the right. The destructive button stays disabled until the typed text matches.

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
| Agents | `Agents` | `AgentsDark` | FR-RC05–FR-RC07 |
| Tokens | `Tokens` | — | this page |
| Sidebar component | `Sidebar` | — | FR-CN13 |

Not yet drawn (follow the same components): welcome screen, string / list / set / zset / stream editors, new-key sheet, command palette, Settings panes other than Agents, error states for each connection category.

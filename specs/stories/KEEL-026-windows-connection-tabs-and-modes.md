# KEEL-026 · Windows, connection tabs and modes

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 8 pts | S4 | [KEEL-017](KEEL-017-sidebar-of-connections.md), [KEEL-003](KEEL-003-owner-only-versioned-persistence.md) |

**Specs:** [FR-AP01](../03-functional-requirements.md#7-app-basics), [FR-CN15](../03-functional-requirements.md#1-connections), [MAC-05](../07-macos-support.md#native-behavior), [08 Design → Tab bar](../08-design.md#tab-bar)

## Story

As a user, I want several windows with one tab per connection and Browser / Console / Info modes, so that I can work on multiple servers side by side.

## Scope

- Window → tabs (profile, db, mode) persisted in `windows.json`; the selected key stays in memory (key names from browsing are never persisted, 02 Architecture)
- Tab bar per design; drag tabs between windows; automatic window tabbing disabled
- Toolbar: connection name, db picker, centered mode switch (⌘1/⌘2/⌘3), search icon
- Restore disconnected unless Reconnect on launch (never auto for Production)

## Acceptance criteria

- [x] **AC1.** Two windows can show different tabs of the same profile.
- [x] **AC2.** Windows, tabs, modes and dbs restore after relaunch, disconnected.
- [ ] **AC3.** Closing a tab with unsaved edits asks first.
- [ ] **AC4.** Toolbar and tabs match the `Main` board (manual design review).

### Verification notes

- AC1 observed in `WindowModelTests.testTabsPersistAndRestoreDisconnected` (two windows with tabs of the same profile on db2 and db5, all connected, profile status across windows) and in the running app (`swift run Keel --state-directory …` with a seeded `windows.json` against a local `redis-server` 8.x on port 6390): the two `local-dev` tabs, in different windows on db0 and db1, opened two `keel` clients (`CLIENT LIST`: db=0 and db=1), each sending `HELLO`, `INFO`, `COMMAND`, `CONFIG GET databases`, `DBSIZE` and `SCAN` — no `KEYS`.
- AC2 observed in `testTabsPersistAndRestoreDisconnected` (windows, order, tabs, modes, dbs, selection and frames restore; every tab disconnected; no connect; the file holds no status or key name), `testDeletedProfilesTabsCloseInEveryWindowAndAreNotRestored` and `SessionConnectorTests.testRestorableWindows` (bounds, repeated IDs, stale selection). `testProductionNeverAutoReconnects`: of four profiles with Reconnect on launch, only the non-production one connects (red label and an opted-in label stay disconnected). The same held in the running app: the `payments-prod` tab (red, Reconnect on launch on) stayed disconnected while `local-dev` reconnected; `windows.json` was rewritten 0600 with the same windows, tabs, modes and frames.
- `testMoveTabBetweenWindows`: a dragged tab keeps its session (no new connect, status follows it), the target selects it, the source selects the neighbor; reorder within a window; Move to New Window; closing a window ends its tabs' sessions. `testModeShortcuts`: ⌘1/⌘2/⌘3 map to Browser/Console/Info and change only the selected tab (saved); nothing without a tab; ⇧⌘]/⇧⌘[ wrap.
- `SessionConnectorTests`: the real connector against an in-memory server — password and database in the handshake, identification, `CONFIG GET databases`, the read-only policy on the new data path, everything closed after a refused server (Redis 5) or a wrong password, and a close that releases once.
- Review: `SessionConnectorReviewTests` (no connection reopens after close; repeated window IDs restore once) and `WindowModelReviewTests` (an unusable `connections.json` never overwrites `windows.json`; a window opened during the launch restore is kept).
- AC3 is implemented and observed only at the model level (`testClosingATabWithUnsavedEditsAsksFirst`: the first close only asks and keeps the tab and its connection; confirming closes it and ends the session). **Pending** until KEEL-027's editors can produce unsaved edits and the confirmation is seen in the app, together with the window-close alert (MAC-06).
- **Pending:** AC4 manual design review in light and dark (screenshots weren't possible in this environment); dragging a tab *out* of every tab bar to make a new window (FR-AP01) — only drags between tab bars and **Move to New Window** are implemented; VoiceOver pass of the tab bar and mode switch; Console and Info modes show a placeholder until KEEL-041 / KEEL-042; the ⌘K search icon is inactive until KEEL-048; Intel and multi-display frame restore on real hardware.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `WindowModelTests.testTabsPersistAndRestoreDisconnected` | Tabs persist and restore disconnected |
| `WindowModelTests.testMoveTabBetweenWindows` | Move tab between windows |
| `WindowModelTests.testProductionNeverAutoReconnects` | Production never auto reconnects |
| `WindowModelTests.testModeShortcuts` | Mode shortcuts |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

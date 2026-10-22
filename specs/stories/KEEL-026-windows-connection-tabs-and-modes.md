# KEEL-026 · Windows, connection tabs and modes

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 8 pts | S4 | [KEEL-017](KEEL-017-sidebar-of-connections.md), [KEEL-003](KEEL-003-owner-only-versioned-persistence.md) |

**Specs:** [FR-AP01](../03-functional-requirements.md#7-app-basics), [FR-CN15](../03-functional-requirements.md#1-connections), [MAC-05](../07-macos-support.md#native-behavior), [08 Design → Tab bar](../08-design.md#tab-bar)

## Story

As a user, I want several windows with one tab per connection and Browser / Console / Info modes, so that I can work on multiple servers side by side.

## Scope

- Window → tabs (profile, db, mode, selected key path) persisted in `windows.json`
- Tab bar per design; drag tabs between windows; automatic window tabbing disabled
- Toolbar: connection name, db picker, centered mode switch (⌘1/⌘2/⌘3), search icon
- Restore disconnected unless Reconnect on launch (never auto for Production)

## Acceptance criteria

- [ ] **AC1.** Two windows can show different tabs of the same profile.
- [ ] **AC2.** Windows, tabs, modes and dbs restore after relaunch, disconnected.
- [ ] **AC3.** Closing a tab with unsaved edits asks first.
- [ ] **AC4.** Toolbar and tabs match the `Main` board (manual design review).

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

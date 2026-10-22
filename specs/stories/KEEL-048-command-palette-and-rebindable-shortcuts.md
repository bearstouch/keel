# KEEL-048 · Command palette and rebindable shortcuts

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 5 pts | S8 | [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [FR-AP02, FR-AP03](../03-functional-requirements.md#7-app-basics), [Default shortcuts](../03-functional-requirements.md#default-shortcuts)

## Story

As a keyboard-first user, I want ⌘K to reach anything and shortcuts I can rebind, so that I rarely need the mouse.

## Scope

- Palette: fuzzy search over actions, connections, tabs, databases, recent keys (memory) and settings
- Shortcut bindings via vendored `KeyboardShortcuts` with conflict detection; menus built from bindings; Settings → Keyboard

## Acceptance criteria

- [ ] **AC1.** ⌘K, "prod pay", Return opens payments-prod.
- [ ] **AC2.** Binding a shortcut already in use is rejected naming the conflicting action.
- [ ] **AC3.** Non-rebindable system items stay fixed.
- [ ] **AC4.** All configurable shortcuts include ⌘.

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `PaletteSearchTests.testFuzzyRanking` | Fuzzy ranking |
| `PaletteSearchTests.testRecentKeysAreMemoryOnly` | Recent keys are memory only |
| `ShortcutBindingsTests.testConflictRejected` | Conflict rejected |
| `ShortcutBindingsTests.testDefaultsMatchSpecTable` | Defaults match spec table |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

# KEEL-043 · Command palette and rebindable shortcuts

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

- [x] **AC1.** ⌘K, "prod pay", Return opens payments-prod. *(CommandPaletteTests.testProdPayReturnOpensPaymentsProd through the palette model and the app's tabs; PaletteSearchTests.testFuzzyRanking)* **Pending:** the keystroke run in the launched app and a design review of the palette and Settings → Keyboard in light and dark.
- [x] **AC2.** Binding a shortcut already in use is rejected naming the conflicting action. *(ShortcutBindingsTests.testConflictRejected: ⌘R for New Tab names Refresh, nothing changes or is saved)*
- [x] **AC3.** Non-rebindable system items stay fixed. *(ShortcutBindingsTests.testDefaultsMatchSpecTable: every fixed chord is reserved and refused; Revert ⌘Z is fixed like Undo)*
- [x] **AC4.** All configurable shortcuts include ⌘. *(ShortcutBindingsTests.testDefaultsMatchSpecTable: every default has ⌘, ⌃L is refused)*

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `PaletteSearchTests.testFuzzyRanking` | Fuzzy ranking |
| `PaletteSearchTests.testRecentKeysAreMemoryOnly` | Recent keys are memory only |
| `ShortcutBindingsTests.testConflictRejected` | Conflict rejected |
| `ShortcutBindingsTests.testDefaultsMatchSpecTable` | Defaults match spec table |

## Notes

- Defaults are read from the spec's table by the test, so the table and `KeelShortcut` can't drift apart.
- Toggle console panel (⌘J) and Zoom data font (⌘+ / ⌘− / ⌘0) keep their chords reserved but stay out of the menus
  and the palette until those features ship (03 → Default shortcuts).
- Follow-ups: Toggle Tree / Flat (sent to the first responder) isn't offered by the palette; Delete Selected Keys… is
  left out when a text field had focus as ⌘K was pressed; the mode switch's tooltip and the console's context menu
  still show default chords; a recent key revealed during the first page load can be loaded twice (the editor dedupes).

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

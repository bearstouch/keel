# KEEL-022 · Virtualized key list (tree and flat)

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 8 pts | S4 | [KEEL-021](KEEL-021-namespace-tree-and-binary-safe-names.md) |

**Specs:** [FR-KB03, FR-KB04](../03-functional-requirements.md#2-key-browser), [NFR-PF02](../04-non-functional-requirements.md#performance), [08 Design → Key list](../08-design.md#key-list)

## Story

As a user, I want the key list to stay smooth with millions of keys, in tree or flat view, so that the app feels instant.

## Scope

- AppKit `NSOutlineView` (tree) and `NSTableView` (flat) hosted in SwiftUI, view-based reuse, 32 px rows per design
- ⇧⌘T toggles views keeping selection; keyboard navigation; context menu

## Acceptance criteria

- [ ] **AC1.** 1M loaded keys scroll at display frame rate (hitch ratio < 5 ms/s).
- [ ] **AC2.** Switching views keeps the selected key.
- [ ] **AC3.** Rows expose name, type and TTL to VoiceOver.
- [ ] **AC4.** The list matches the `Main` board (manual design review).

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `KeyListDataSourceTests.testRowCountMatchesVisibleTree` | Row count matches visible tree |
| `KeyListDataSourceTests.testSelectionSurvivesViewToggle` | Selection survives view toggle |
| `KeyListDataSourceTests.testAccessibilityLabels` | Accessibility labels |

## Integration and manual checks

- Instruments Animation Hitches on 1M keys recorded by `scripts/bench-browser.py`.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

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
- [x] **AC2.** Switching views keeps the selected key.
- [x] **AC3.** Rows expose name, type and TTL to VoiceOver.
- [ ] **AC4.** The list matches the `Main` board (manual design review).

### Verification notes

- AC1 **pending**: needs Instruments' Animation Hitches on a real window with 1M keys (`scripts/bench-browser.py`, KEEL-052). Proxy in `KeyListPerformanceTests` (release, Apple silicon, 1M keys): filling the rows of a scrolled-to page takes ~8 ms (tree) / ~6 ms (flat), under one 60 Hz frame. Only visible rows (plus a 64-row margin) are ever fetched.
- FR-KB04's "expanding a node with 500,000 children is under 200 ms" is **not met** with `NSOutlineView`: ~0.36 s in release, of which `NSOutlineView.expandItem` itself is ~0.3 s (our data-source callbacks ~40 ms, the index's sort ~40 ms). Keeping `NSOutlineView` per this story's scope was a deliberate decision; the test guards the expand at 500 ms against regressions. A flattened `NSTableView` tree is the known way to reach 200 ms if needed.
- AC2 observed in `KeyListDataSourceTests.testSelectionSurvivesViewToggle`: flat → tree expands the key's folder and selects it, tree → flat selects the same key; a reload keeps it and a restart that puts another key at that index clears it.
- AC3 observed in `KeyListDataSourceTests.testAccessibilityLabels`: each row's cell is the accessibility element with "user, 3 keys" / "1, hash" / "user:1042, sorted set, expires in 3d"; badges are text (DS-04). TTLs arrive with KEEL-024. A VoiceOver pass on a real window is **pending**.
- AC4 **pending** formal review: an offscreen render of the pane in light and dark was compared against the `Main` board (32 px rows, 18 px indent, muted counts, 40 px badges, rounded `selection` fill, footer). Inter / JetBrains Mono fall back to system fonts until KEEL-049 bundles them. The pane isn't on screen in the app yet: the browser that owns a tab's `KeyIndex` arrives with KEEL-025/026.
- ⇧⌘T is View → Toggle Tree / Flat, sent to the first responder, so it works while the list has focus. Keyboard navigation (arrows, ←/→ collapse/expand) is AppKit's; type-select is off because names are fetched lazily (KEEL-023 brings filters). The context menu copies a key name, a redis-cli argument or a folder path from the original bytes.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `KeyListDataSourceTests.testRowCountMatchesVisibleTree` | Row count matches visible tree |
| `KeyListDataSourceTests.testSelectionSurvivesViewToggle` | Selection survives view toggle |
| `KeyListDataSourceTests.testAccessibilityLabels` | Accessibility labels |
| `KeyListPerformanceTests.testOneMillionKeysExpandAndScrollUnderBudget` | 1M keys: page fill under a frame, 500k expand regression guard |
| `KeyListDataSourceReviewTests` | Click after restart doesn't read past the index; re-expanded folder shows keys loaded while collapsed; rows scrolled in during a fetch are filled |
| `NamespaceTreeReviewTests.testAncestorsAndFullNamesForTheKeyList` | Key ancestors (reveal) and full names for the flat view |

## Integration and manual checks

- Instruments Animation Hitches on 1M keys recorded by `scripts/bench-browser.py`.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

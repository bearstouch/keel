# KEEL-027 · Editor shell, save bar and conflicts

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S5 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md), [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md) |

**Specs:** [03 → Value editors common rules](../03-functional-requirements.md#3-value-editors), [FR-ED13](../03-functional-requirements.md#3-value-editors), [08 Design → Editor](../08-design.md#editor)

## Story

As a user, I want a calm editor with one metadata line, actions in ⋯ and a save bar only when I change something, so that editing is clear and safe.

## Scope

- Header: key (mono), type badge, ⋯ (Rename, Set TTL, Copy, Delete, Details); metadata line "Expires in 3 days · 6 fields"
- Floating save bar ("1 unsaved change · Revert · Save"), ⌘S / ⌘Z, changed-row dot
- Whole-value saves with `WATCH` + `MULTI/EXEC`; `CONFLICT` offers Reload / Overwrite
- Read-only view: lock + "Read-only" in metadata, no add/save, write actions disabled

## Acceptance criteria

- [ ] **AC1.** The save bar appears only while there are unsaved changes.
- [ ] **AC2.** A concurrent change between load and save reports `CONFLICT`; nothing is overwritten unless the user chooses Overwrite.
- [ ] **AC3.** Read-only profiles show no Save or Add controls and send no writes.
- [ ] **AC4.** Details shows encoding, exact TTL and memory size on request, or "unavailable".

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `EditorSessionTests.testDirtyStateDrivesSaveBar` | Dirty state drives save bar |
| `EditorSessionTests.testWatchConflictReported` | fake server changes key |
| `EditorSessionTests.testRevertRestoresLoadedValue` | Revert restores loaded value |
| `EditorSessionTests.testReadOnlyDisablesWrites` | Read only disables writes |
| `KeyDetailsTests.testUnavailableWhenUnsupported` | Unavailable when unsupported |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

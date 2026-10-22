# KEEL-036 · New key sheet

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S6 | [KEEL-029](KEEL-029-string-editor.md), [KEEL-030](KEEL-030-hash-editor.md), [KEEL-031](KEEL-031-list-editor.md), [KEEL-032](KEEL-032-set-editor.md), [KEEL-033](KEEL-033-sorted-set-editor.md), [KEEL-034](KEEL-034-stream-viewer-and-add-entry.md) |

**Specs:** [FR-ED14](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to create a key of any type with its first value and an optional TTL, so that I can seed data quickly.

## Scope

- ⇧⌘N sheet: name prefilled with the selected namespace + separator, type picker, first value(s), TTL
- Create-only semantics (`SET NX`; EXISTS inside WATCH/MULTI for other types)

## Acceptance criteria

- [ ] **AC1.** Creating an existing key shows "Key already exists" and creates nothing.
- [ ] **AC2.** The new key is selected after creation.
- [ ] **AC3.** The sheet is blocked on read-only profiles.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `NewKeyTests.testCreateOnlySemanticsPerType` | Create only semantics per type |
| `NewKeyTests.testPrefillsNamespace` | Prefills namespace |
| `NewKeyTests.testBlockedOnReadOnly` | Blocked on read only |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

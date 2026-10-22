# KEEL-031 · List editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S5 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [FR-ED03](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to page through lists and edit, push, pop and remove items, so that I can manage queues safely.

## Scope

- `LRANGE` pages of 500, jump to index
- `LSET`, `LPUSH`/`RPUSH`, `LPOP`/`RPOP`, `LINSERT`, delete-by-index via sentinel + `LREM 1` in MULTI with WATCH

## Acceptance criteria

- [ ] **AC1.** Deleting index 3 of 10 items leaves 9 in order.
- [ ] **AC2.** A list changed elsewhere since the page loaded reports `CONFLICT` on index edits.
- [ ] **AC3.** Pop actions require a normal confirmation on production profiles.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ListEditorTests.testPagesWithLRange` | Pages with lrange |
| `ListEditorTests.testDeleteByIndexPreservesOrder` | Delete by index preserves order |
| `ListEditorTests.testIndexEditConflict` | Index edit conflict |
| `ListEditorTests.testSentinelIsUniquePerOperation` | Sentinel is unique per operation |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

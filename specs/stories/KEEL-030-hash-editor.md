# KEEL-030 · Hash editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S5 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [FR-ED02](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to add, edit, rename and delete hash fields, so that I can maintain records like `user:1042`.

## Scope

- Field/value table; `HGETALL` for ≤ 1,000 fields, `HSCAN` COUNT 500 + Load more beyond
- Add (`HSET`), edit, rename (HSET new + HDEL old in MULTI), delete (`HDEL`); local filter

## Acceptance criteria

- [ ] **AC1.** Renaming onto an existing field asks before overwriting.
- [ ] **AC2.** A 1M-field hash shows its first page in < 1 s.
- [ ] **AC3.** Each edit is atomic; a failed rename leaves both fields as they were.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `HashEditorTests.testSmallHashUsesHGetAll` | Small hash uses hget all |
| `HashEditorTests.testLargeHashPagesWithHScan` | Large hash pages with hscan |
| `HashEditorTests.testRenameFieldIsAtomic` | MULTI contents |
| `HashEditorTests.testRenameOntoExistingAsks` | Rename onto existing asks |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

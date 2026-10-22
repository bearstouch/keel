# KEEL-038 · Typed confirmations and multi-key delete

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S6 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md) |

**Specs:** [FR-SF03, FR-SF04, FR-SF08](../03-functional-requirements.md#5-safety)

## Story

As a user, I want destructive actions to need me to type what I'm destroying, so that a slip of the keyboard can't wipe data.

## Scope

- Shared typed-confirmation sheet: count for multi-key delete, pattern for bulk delete, `db3` for FLUSHDB, profile name for FLUSHALL
- Multi-key delete via `UNLINK` batches of 500
- O(N) warnings in the console (KEYS, unbounded reads on > 10,000 elements, FLUSHALL without ASYNC)

## Acceptance criteria

- [ ] **AC1.** The destructive button stays disabled until the text matches exactly; Return never confirms.
- [ ] **AC2.** Deleting 2,000 selected keys sends 4 UNLINK commands.
- [ ] **AC3.** On Production, the sheet also names the server.

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `TypedConfirmationTests.testExactMatchRequired` | case and whitespace |
| `TypedConfirmationTests.testReturnDoesNotConfirm` | Return does not confirm |
| `MultiKeyDeleteTests.testBatchesOf500` | Batches of500 |
| `ComplexityWarningTests.testWarnsOnLargeKeys` | Warns on large keys |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

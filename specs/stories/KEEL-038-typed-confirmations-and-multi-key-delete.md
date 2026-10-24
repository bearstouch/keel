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

- [x] **AC1.** The destructive button stays disabled until the text matches exactly; Return never confirms.
- [x] **AC2.** Deleting 2,000 selected keys sends 4 UNLINK commands.
- [x] **AC3.** On Production, the sheet also names the server.

### Verification notes

- AC1 observed at the model level in `TypedConfirmationTests.testExactMatchRequired` (count, `db3`, profile name and pattern: near matches differing in case, whitespace or a trailing newline leave `canConfirm` false and `confirm()` runs nothing; the exact text enables it) and `testReturnDoesNotConfirm` (the field's Return handler never runs the action). The sheet's button is bound to `canConfirm` and has no keyboard shortcut; clicking through the sheet in the running app, in light and dark, is **pending**.
- AC2 observed in `MultiKeyDeleteTests.testBatchesOf500` (2,000 keys → 4 `UNLINK` frames of 500, in selection order) and end to end through the browser in `TypedConfirmationTests.testDeletingSelectedKeysAsksForTheCountAndRemovesThem` (multi-row selection → sheet expecting "3" and listing the names → nothing sent before the typed text → one `UNLINK` → keys leave the list and the total).
- AC3 observed in `TypedConfirmationTests.testProductionSheetNamesTheServer` (production → "Server: cache.internal:6379", also via the policy's FLUSHDB request; non-production → none). The rendered chip in the running app is **pending**.
- Also: `MultiKeyDeleteTests` failure safety (unconfirmed, confirmed for other keys or another database, read-only: nothing sent; a server error stops after the batches already answered; duplicates counted once; cancellation), `ComplexityWarningTests` (FR-SF08), `testDeleteKeyPressOpensTheSheet`, `testReadOnlyNeverAsks`, `testFailedActionIsNotOfferedAgain`.
- Review fixes: read-only tabs offer no ⌫ / Delete N Keys… (only Copy N Key Names); a selection changed while its names were read opens no sheet (`TypedConfirmationReviewTests`, `MultiKeyDeleteReviewTests` also cover `KeyIndex.remove(keys:)` and the generation guard).
- Follow-ups (from review, not applied): no feedback when ⌫ meets a stale selection; a SCAN page in flight can re-add a just-deleted key (as for single delete); ⌘A on a huge flat list selects every row and runs all batches on the browser connection (cap or route to a bulk job); typed text is compared as raw UTF-8 (no Unicode normalization); a partial failure says to refresh but doesn't trigger one.
- Pending: the console shows `ComplexityWarning` and the typed sheet for FLUSHDB / FLUSHALL when it arrives (KEEL-041); bulk delete by pattern uses the same sheet (KEEL-039); VoiceOver pass over the sheet (KEEL-045); real servers (KEEL-048).

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

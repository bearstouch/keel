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

- [x] **AC1.** Deleting index 3 of 10 items leaves 9 in order.
- [x] **AC2.** A list changed elsewhere since the page loaded reports `CONFLICT` on index edits.
- [x] **AC3.** Pop actions require a normal confirmation on production profiles.

### Verification notes

- AC1 observed in `ListEditorTests.testDeleteByIndexPreservesOrder` (`[a,b,c,b,e…j]` minus index 3 leaves the other 9 in order, with a duplicate `b` before it; `WATCH`, `LRANGE q 3 3`, `MULTI`, `LSET q 3 <sentinel>`, `LREM q 1 <sentinel>`, `EXEC`; an edit plus two deletes in one save) and `ListEditorSessionTests.testEditAndDeleteByIndexSave`.
- AC2 observed in `ListEditorTests.testIndexEditConflict` (an `LPUSH` elsewhere makes both an `LSET` edit and a delete a `CONFLICT` with nothing written; an `RPUSH` past the touched span doesn't block the save) and `ListEditorSessionTests.testPopRunsAtOnceAndIsGuarded`.
- AC3 observed in `ListEditorSessionTests.testPopAsksOnProduction` (KeelUITests: Pop Head on a production profile sets `pendingPop` and sends nothing; Cancel pops nothing; confirmed, `RPOP` runs) and `SessionConnectorTests.testProductionLabelReachesSafetyProfile` (the label's "treat as production" reaches `SafetyProfile.production`). Seeing the alert in the running app, light and dark, and a VoiceOver pass are **pending**.
- Review fixes: after a list `CONFLICT` the alert offers Reload only, because Overwrite would apply index edits to items that moved (`ListEditorSessionReviewTests.testConflictOffersNoOverwriteForIndexEdits`); a list save with an unknown outcome replaces the draft with the server's value, so a second Save can't delete the wrong items (`testUnknownOutcomeReplacesDraft`).
- Follow-ups: a save that succeeds but whose read-back fails sets `loaded` to the draft's stale indexes (the guard then turns the next action into a `CONFLICT`); a list emptied by a save or pop shows "No items." and still allows Push, as the hash editor does; after a failed save, push, pop, insert and Jump stay disabled until Reload, and nothing says why; with identical duplicate values the span guard can't see a shift, but the item removed has the same bytes; push and insert take UTF-8 text only (binary values are edited in the viewer afterwards).

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

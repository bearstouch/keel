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

- [x] **AC1.** Renaming onto an existing field asks before overwriting.
- [ ] **AC2.** A 1M-field hash shows its first page in < 1 s.
- [x] **AC3.** Each edit is atomic; a failed rename leaves both fields as they were.

### Verification notes

- AC1 observed in `HashEditorTests.testRenameOntoExistingAsks` (rename and add onto an existing field return `confirmOverwrite`; confirmed, the value moves and the old field is removed) and `HashEditorSessionTests.testRenameOntoExistingAsksThenSavesAtomically` (nothing changes until confirmed). For a hash not fully loaded, the server is asked about an unloaded target (`testPagedHashLoadsMoreAndAsksAboutUnloadedFields`). Seeing the alert in the running app, light and dark, and a VoiceOver pass are **pending**.
- AC2 **pending**: `HashEditorTests.testLargeHashPagesWithHScan` shows a large hash sends only `HLEN` + `HSCAN h 0 COUNT 500` (never `HGETALL`) and pages are bounded to 8 rounds (`testScanPageIsBounded`), but the under-1 s first page on a real 1M-field hash is not measured (KeelIntegrationTests / KEEL-047 bench).
- AC3 observed in `HashEditorTests.testRenameFieldIsAtomic` (`WATCH`, `HGET` of both fields, `MULTI`, `HSET h mail …`, `HDEL h email`, `EXEC`) and `testFailedRenameLeavesBothFields` (another client's write before `EXEC` → `CONFLICT`, neither write ran); `HashEditorSessionTests.testChangedFieldConflicts`.
- Review fix: a "Load more" page landing after a Reload is dropped instead of merged into the reloaded value (`HashEditorSessionReviewTests.testLoadMoreLandingAfterReloadIsDropped`).
- Follow-ups: a failed save hides the table until Revert; a field another client creates after Add's server check is overwritten without asking if Load more returns it; an Add whose check lands during a save is dropped silently; guard reads are sequential (one `HGET` per touched field); keystroke cost grows with many loaded pages (re-sort and diff); invalid JSON/Raw text is dropped on selection change; a key deleted between `HLEN` and `HSCAN` shows "No fields.".

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

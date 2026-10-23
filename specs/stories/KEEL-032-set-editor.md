# KEEL-032 · Set editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 2 pts | S6 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [FR-ED04](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to browse, add and remove set members, so that I can maintain flags and memberships.

## Scope

- `SMEMBERS` when `SCARD` ≤ 1,000 else `SSCAN`; add `SADD`, remove `SREM`; local filter; count

## Acceptance criteria

- [x] **AC1.** Adding an existing member reports "already a member".
- [x] **AC2.** Large sets page with SSCAN.

### Verification notes

- AC1 observed in `SetEditorTests.testAddExistingReportsAlreadyMember` (`SADD s red` on a set holding `red` replies `[0]` → `.alreadyMember`, the set unchanged; `SADD s blue` → `.added`) and `SetEditorSessionTests.testAddExistingShowsAlreadyMember` / `testLargeSetPagesAndAddsUnloadedMember` (KeelUITests: the model shows "Already a member of this set.", selects the member, also when it lies beyond the loaded pages).
- AC2 observed in `SetEditorTests.testChoosesSMembersOrSScan` (3 and exactly 1,000 members → `SCARD`, `SMEMBERS`; 1,001 → `SCARD`, `SSCAN s 0 COUNT 500`), `testLargeSetPagesWithSScan` (1,200 members over three pages, never `SMEMBERS`), `testScanPageIsBounded` and `SetEditorSessionTests.testLargeSetPagesAndAddsUnloadedMember` ("Showing 1–500 of 1,200", Load more to the end).
- Removals save as one `SREM` in `MULTI/EXEC` (`testRemoveSavesOneSRem`, `testRemoveSavesOneSRemAndRereadKeepsPages`); read-only profiles send no `SADD` (`testReadOnlyRefusesAdd`). Seeing the editor in the running app, light and dark, a VoiceOver pass and the 1M-member timing against a real server are **pending**.
- Review fix: a member shown in JSON view that isn't valid JSON no longer blocks saving removals, since the member viewer is read-only (`SetEditorSessionReviewTests.testInvalidJSONMemberInJSONViewDoesNotBlockSave`). An empty first `SSCAN` page with cursor 0 now reports the key as gone.
- Follow-ups: removals have no guard reads (documented in FR-ED04); an add with an unknown outcome doesn't show the member (only `SCARD` reflects it); a fully loaded set isn't re-read after an add; the read-back sends one `SISMEMBER` per removed member (`SMISMEMBER` needs 6.2+); the Add tooltip names unsaved changes even when another state disables it; `pageText` counts members included by an add; Add takes UTF-8 text only.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `SetEditorTests.testChoosesSMembersOrSScan` | Chooses smembers or sscan |
| `SetEditorTests.testAddExistingReportsAlreadyMember` | Add existing reports already member |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

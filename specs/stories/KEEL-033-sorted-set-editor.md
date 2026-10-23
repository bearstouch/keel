# KEEL-033 · Sorted set editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S6 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md), [KEEL-011](KEEL-011-server-detection-capability-probes-and-minimum-version.md) |

**Specs:** [FR-ED05](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want members sorted by score with add, change score and remove, so that leaderboards and schedules are easy to inspect.

## Scope

- `ZRANGE … BYSCORE … LIMIT` (6.2+) or `ZRANGEBYSCORE` paging, ascending/descending
- `ZSCAN` for pattern search; `ZADD`, `ZADD XX`, `ZINCRBY`, `ZREM`; full precision and ±inf

## Acceptance criteria

- [x] **AC1.** A 100k-member zset shows lowest scores first and pages forward.
- [x] **AC2.** Changing a score moves the row after save.
- [x] **AC3.** On Redis 6.0 the editor uses `ZRANGEBYSCORE`.

### Verification notes

- AC1 observed in `SortedSetEditorTests.testLargeSetShowsLowestFirstAndPagesForward` (100,000 members in an in-memory server: the first page is the 500 lowest scores, three Load more pages continue contiguously to 2,000, never `ZSCAN`), `testTiedScoresPageWithoutGapsOrRepeats` and the review tests `testDescendingTiesPageWithoutGapsOrRepeats` / `testInfiniteScoresPage` (members sharing a score page through `LIMIT` skips with no gaps or repeats, both directions, `±inf`).
- AC2 observed in `SortedSetEditorSessionTests.testChangedScoreMovesAfterSave` (KeelUITests: the edited row keeps its place until Save; Save sends `MULTI`, `ZADD board XX 25.5 bob`, `EXEC`, guarded by `ZSCORE`, and the row then moves between its new neighbours).
- AC3 observed in `SortedSetEditorTests.testPagingCommandByCapability` (a server refusing `BYSCORE` gets `ZRANGEBYSCORE z -inf +inf WITHSCORES LIMIT 0 500` / `ZREVRANGEBYSCORE`, probed once per session; a 6.2+ server gets `ZRANGE … BYSCORE [REV] … LIMIT`).
- Full precision and `inf` in `testScoreFormattingFullPrecision`; `ZADD XX` and the `ZSCORE` guard (a Redis 6 `%.17g` reply matches the loaded double; a score changed elsewhere is `CONFLICT`) in `testChangeScoreUsesXX`. Seeing the editor in the running app, light and dark, a VoiceOver pass and the 100k-member timing against real Redis 6.0 / 7.x / Valkey containers are **pending**.
- Review fixes: an add or increment whose reply is lost now re-reads the member's score (`ZSCORE`) instead of leaving the old one shown, never re-sending (`SortedSetEditorSessionReviewTests.testUnknownIncrementOutcomeRereadsTheScore`); a search match removed by a save no longer reappears in the results (`testSavedRemovalLeavesSearchResults`).
- Follow-ups: the capability probe closure keeps the first context's database; `search()` doesn't refuse a second search while one runs; `pageText` counts rows placed beyond the loaded pages; the VoiceOver Increment action isn't disabled while unsaved edits block it (the model refuses it); search results are a snapshot after Reload; `-0` is sent as `0`.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `SortedSetEditorTests.testPagingCommandByCapability` | Paging command by capability |
| `SortedSetEditorTests.testScoreFormattingFullPrecision` | Score formatting full precision |
| `SortedSetEditorTests.testChangeScoreUsesXX` | Change score uses xx |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

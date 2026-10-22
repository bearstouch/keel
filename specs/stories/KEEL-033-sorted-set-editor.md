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

- [ ] **AC1.** A 100k-member zset shows lowest scores first and pages forward.
- [ ] **AC2.** Changing a score moves the row after save.
- [ ] **AC3.** On Redis 6.0 the editor uses `ZRANGEBYSCORE`.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `SortedSetEditorTests.testPagingCommandByCapability` | Paging command by capability |
| `SortedSetEditorTests.testScoreFormattingFullPrecision` | Score formatting full precision |
| `SortedSetEditorTests.testChangeScoreUsesXX` | Change score uses xx |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

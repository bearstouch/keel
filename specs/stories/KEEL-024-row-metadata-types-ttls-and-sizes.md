# KEEL-024 · Row metadata: types, TTLs and sizes

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 5 pts | S5 | [KEEL-022](KEEL-022-virtualized-key-list-tree-and-flat.md) |

**Specs:** [FR-KB06, FR-KB07](../03-functional-requirements.md#2-key-browser), [NFR-PF07](../04-non-functional-requirements.md#performance)

## Story

As a user, I want each row's type and expiry, and sizes only when I ask, so that the list is informative but cheap for the server.

## Scope

- Pipelined `TYPE` + `PTTL` for visible rows, debounced (≤ 1 batch / 100 ms)
- Type badges; short TTL only for expiring keys; local countdown; "expired"
- "Show sizes" (⋯ menu) → `MEMORY USAGE key SAMPLES 0` for visible rows in batches of ≤ 100

## Acceptance criteria

- [ ] **AC1.** Without Show sizes, no `MEMORY USAGE` is sent.
- [ ] **AC2.** Idle list sends no commands for 60 s (countdowns are local).
- [ ] **AC3.** A key with `EXPIRE 90` shows "1m 30s" and becomes "expired".
- [ ] **AC4.** Badges have text so color isn't the only signal.

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `RowMetadataLoaderTests.testBatchesVisibleRowsOnly` | Batches visible rows only |
| `RowMetadataLoaderTests.testDebounce` | injected clock |
| `RowMetadataLoaderTests.testSizesOnlyOnRequest` | Sizes only on request |
| `TTLFormatterTests.testShortForms` | s/m/h/d |
| `RowMetadataLoaderTests.testIdleSendsNothing` | Idle sends nothing |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

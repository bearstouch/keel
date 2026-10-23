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

- [x] **AC1.** Without Show sizes, no `MEMORY USAGE` is sent.
- [x] **AC2.** Idle list sends no commands for 60 s (countdowns are local).
- [x] **AC3.** A key with `EXPIRE 90` shows "1m 30s" and becomes "expired".
- [x] **AC4.** Badges have text so color isn't the only signal.

### Verification notes

- AC1 observed in `RowMetadataLoaderTests.testBatchesVisibleRowsOnly` / `testSizesOnlyOnRequest` against a recording fake server: browsing sends only `TYPE` + `PTTL` for the rows on screen; with Show sizes on, 250 visible rows are measured as `MEMORY USAGE key SAMPLES 0` in batches of 100, 100 and 50, each 100 ms after the last, and turning it off sends nothing more.
- AC2 observed in `RowMetadataLoaderTests.testIdleSendsNothing` (60 one-second ticks of an injected clock with the same rows on screen send no command), `testDebounce` / `testNewerRequestReplacesOneWaiting` (≤ 1 batch per 100 ms; a newer request replaces one waiting) and `RowMetadataLoaderReviewTests.testFailingBatchIsNotResentInALoop`. The countdown (`KeyListRowMetadataTests.testTTLCountsDownLocally`) only re-reads the clock.
- AC3 observed in `KeyListRowMetadataTests.testTTLCountsDownLocally`: a `PTTL` of 90,000 ms shows "1m 30s" (VoiceOver: "expires in 1 minute 30 seconds"), "1m" after 30 s and "expired" after 90 s; a key `TYPE`/`PTTL` report gone reads "expired" and is marked stale.
- AC4 observed in `KeyListRowMetadataTests.testBadgesHaveText`: every loaded type has a text badge and a spoken name; no badge until the type is loaded.
- NFR-RS01 still holds with the new metadata (packed to 8 bytes a key, sizes in a table capped at 65,536): `KeyIndexMemoryTests` measures ~44 B/key index buffers and ~176 B/key heap in total at 100k keys.
- **Pending:** observing it in the running app, since the key list is not yet hosted in a browser window (KEEL-025/026); a protocol trace on real servers (Redis 6.0–8.x, Valkey, Dragonfly, ACL users without `MEMORY`) with the `KeelIntegrationTests` matrix (KEEL-053); VoiceOver pass and light/dark review of the ⋯ menu.

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

# KEEL-020 · SCAN key index

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 8 pts | S4 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md) |

**Specs:** [FR-KB01, FR-KB02](../03-functional-requirements.md#2-key-browser), [02 Architecture → Key index](../02-architecture.md#key-index-and-virtualization), [NFR-RS01, NFR-RS02](../04-non-functional-requirements.md#memory-and-resources)

## Story

As a user browsing a production server, I want keys loaded with SCAN in pages, so that browsing millions of keys never blocks the server.

## Scope

- `KeyIndex` actor: compact byte arena + metadata array, SCAN `COUNT` 1,000 pages, Load more / Auto-page, pause, loaded-key limit (default 1M, max 10M)
- Duplicate keys from SCAN are deduplicated
- Footer text "250,000 of 1.2M keys loaded · Load more" / "All keys loaded"

## Acceptance criteria

- [ ] **AC1.** A protocol trace of browsing shows `SCAN` only, never `KEYS`.
- [ ] **AC2.** Manual mode issues exactly one SCAN per Load more.
- [ ] **AC3.** Auto-page stops at the limit with a notice and Continue.
- [ ] **AC4.** Keys returned twice by SCAN appear once.
- [ ] **AC5.** 1M keys of ~30 bytes use < 200 MB for index and tree (benchmark).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `KeyIndexTests.testNeverSendsKeys` | fake session records commands |
| `KeyIndexTests.testLoadMoreIssuesOneScan` | Load more issues one scan |
| `KeyIndexTests.testAutoPageStopsAtLimit` | Auto page stops at limit |
| `KeyIndexTests.testDeduplicatesScanResults` | Deduplicates scan results |
| `KeyIndexTests.testCursorZeroMarksComplete` | Cursor zero marks complete |
| `KeyIndexMemoryTests.testBytesPerKeyBudget` | measured on 100k synthetic keys |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

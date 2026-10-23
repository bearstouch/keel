# KEEL-047 · Performance benchmarks

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 5 pts | S9 | [KEEL-022](KEEL-022-virtualized-key-list-tree-and-flat.md), [KEEL-024](KEEL-024-row-metadata-types-ttls-and-sizes.md), [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [NFR-PF01–NFR-PF08](../04-non-functional-requirements.md#performance), [NFR-RS01–NFR-RS05](../04-non-functional-requirements.md#memory-and-resources)

## Story

As the team, I want repeatable benchmarks for the 1M-key targets, so that we can prove Keel stays smooth and catch regressions.

## Scope

- `scripts/bench-browser.py`: seeds 1M/10M keys in a container, measures launch, scan ingestion, tree build, scroll hitches, filter, value open, memory
- Evidence JSON in `.build/`

## Acceptance criteria

- [ ] **AC1.** All NFR-PF targets measured on Apple silicon; Intel recorded (pending until hardware available).
- [ ] **AC2.** A regression of > 20% on any metric fails the benchmark job.
- [ ] **AC3.** Results are recorded in the release evidence.

## Unit tests

Test target: `KeelCoreTests (measure tests) + script`.

| Test | Verifies |
| --- | --- |
| `ScanIngestionPerformanceTests.testOneMillionKeys` | XCTest measure with fake transport |
| `TreeBuildPerformanceTests.testOneMillionKeys` | One million keys |
| `ValueOpenPerformanceTests.testLargeCollectionsFirstPage` | Large collections first page |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

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
- [x] **AC2.** A regression of > 20% on any metric fails the benchmark job.
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

## Verification (2026-10-24)

Run on an Apple M1 Pro, 16 GB, macOS 26.6.2, against a local `redis-server` 7.2.1 (Docker was not available):
`python3 scripts/bench-browser.py --redis-server /opt/homebrew/bin/redis-server --update-baseline`, median of 3 runs.
Every metric was within its target, and the run recorded `release/bench-baseline.json` (arm64).

| NFR | Metric (1M keys unless noted) | Measured | Target |
| --- | --- | --- | --- |
| PF01 | Launch to first sidebar render, 200 profiles (slowest of 4; first launch after a build 0.36 s) | 0.26 s | 1.0 s |
| PF02 | Editor header on row select (live) | 0.4 ms | 100 ms |
| PF03 | SCAN ingestion: live / fake transport / 10M live | 1.78 s / 3.23 s / 23.4 s | 15 s (1M) |
| PF04 | Tree rebuild live / expand live (10M: 3.65 s / 1.12 s) | 0.25 s / 90 ms | 2 s / 200 ms |
| PF05 | Filter first results / complete (live) | 2.2 ms / 12 ms | 150 ms / 1 s |
| PF06 | First page: hash 1M, list 10M, set, zset, stream 1M, 64 MiB string (live) | 0.4–1.1 ms | 300 ms |
| PF08 | 10,000-element reply formatted | 7 ms | 500 ms |
| RS01 | Index overhead per key / index and tree at 1M (live) | 34 B / 80 MiB | 120 B / 200 MiB |

- **AC1:** partly met. Measured on Apple silicon, but on an M1 Pro, not the M1 8 GB reference machine. Still
  **pending** by hand: PF02 scroll hitch ratio and PF03 main-thread frame time (Instruments), PF07 idle protocol
  trace, PF08 MONITOR at 50,000 lines/s and text-view layout, PF01 truly cold launch (empty file cache), and the
  Intel reference Mac (no hardware).
- **AC2:** observed. `evaluate` fails a +22% change and passes +16%. A metric missing from a group that ran fails
  the job. A single-run smoke check (`--runs 1`) once flagged a +30% tree build that was noise; the median of 3
  stayed within ±4% of the baseline, so the gate uses 3 runs by default.
- **AC3:** **pending** on KEEL-052. Evidence is written to `.build/bench/evidence.json`; `package-release.sh`,
  which copies it into `release-evidence.json`, doesn't exist yet (scope added to KEEL-052).

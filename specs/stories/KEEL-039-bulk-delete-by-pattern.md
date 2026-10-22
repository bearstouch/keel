# KEEL-039 · Bulk delete by pattern

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S6 | [KEEL-038](KEEL-038-typed-confirmations-and-multi-key-delete.md), [KEEL-020](KEEL-020-scan-key-index.md) |

**Specs:** [FR-SF05, FR-SF06](../03-functional-requirements.md#5-safety)

## Story

As an operator, I want to delete every key matching a pattern in batches with progress and cancel, so that I can clean up millions of keys without blocking the server.

## Scope

- `BulkDeleteJob` on the `job` connection: SCAN MATCH COUNT 1000 + UNLINK, optional type filter, throttle (default 10 batches/s)
- Confirmation sentence + Preview matches (first 100) + typed pattern
- Progress: bar, deleted count, ETA, Cancel; final report with scanned/matched/deleted and SCAN caveat
- Pattern `*` refused

## Acceptance criteria

- [ ] **AC1.** Cancel stops within one batch.
- [ ] **AC2.** Browsing stays responsive during the job.
- [ ] **AC3.** With throttle 2, at most 2 UNLINK batches per second.
- [ ] **AC4.** The report states the deleted count and that keys created during the run may remain.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `BulkDeleteJobTests.testCancelStopsAfterCurrentBatch` | Cancel stops after current batch |
| `BulkDeleteJobTests.testThrottle` | injected clock |
| `BulkDeleteJobTests.testRefusesStarPattern` | Refuses star pattern |
| `BulkDeleteJobTests.testReportCounts` | Report counts |
| `BulkDeleteJobTests.testRunsOnJobConnection` | Runs on job connection |

## Integration and manual checks

- 2M keys `tmp:import:*` on a local container: completes, cancel mid-way verified.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

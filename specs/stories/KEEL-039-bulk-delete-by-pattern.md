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

- [x] **AC1.** Cancel stops within one batch.
- [ ] **AC2.** Browsing stays responsive during the job.
- [x] **AC3.** With throttle 2, at most 2 UNLINK batches per second.
- [x] **AC4.** The report states the deleted count and that keys created during the run may remain.

### Verification notes

- AC1 observed in `BulkDeleteJobTests.testCancelStopsAfterCurrentBatch`: Cancel arrives while the second `UNLINK` is in flight (from the fake server); that batch finishes and counts (2,000 deleted), no third batch is sent, the report says cancelled. Cancel is a lock flag, not task cancellation, so the in-flight reply is never dropped. Also `testCancelBeforeStartSendsNoDelete`, `testCancelDuringSampleLeavesNoConnectionOpen`.
- AC2 **partially observed**: `BulkDeleteJobReviewTests.testBrowserRunsWhileJobWaits` runs browser SCANs on the `browser(db0)` connection while the job (on `job(id)`) waits out its throttle, and the job runs off the main actor. The progress sheet is window-modal (08 Design board `BulkDeleteDark`), so browsing *that window* during the run, and responsiveness with 2M keys in the running app, are **pending** (manual).
- AC3 observed in `BulkDeleteJobTests.testThrottle` with an injected clock: 6 batches at 0, 0.5 … 2.5 s, no window [t, t+1) holds more than 2; unthrottled never sleeps.
- AC4 observed in `testReportCounts` (2,500 of 3,200 keys: 4 SCAN pages, `UNLINK` 1,000 / 1,000 / 500, "Deleted 2,500 keys matching tmp:import:*." plus "Keys created or renamed while it ran may remain.") and through the browser in `BulkDeleteModelTests.testTypedPatternRunsAndReports`.
- Also: `testRefusesStarPattern` (`*`, `**`, empty refused by the job; a `**` confirmation covers no delete in the policy; nothing sent), `testRunsOnJobConnection` (only `job(id)` opened, closed after the run), read-only / wrong-pattern confirmation / server error / run-once / sample estimate and wording in `BulkDeleteJobReviewTests`; UI gating (read-only and no-pattern don't offer it; closing before the run sends nothing) in `BulkDeleteModelTests`.
- Review fixes: the sample no longer reopens the job connection after the sheet closed (no `DBSIZE` after Cancel, closes again at its end) and stops once the run starts; Delete waits for the sample so the two never share the job connection.
- Follow-ups (from review, not applied): the sentence, title and report don't mention an active type filter; a tab closed while the sheet is open leaves the job (and its connection) to the session's close (MAC-06's "cancel running jobs?" prompt and the background notification of MAC-04 are not built); a fast double click can create a second job that replaces the first.
- Pending: the integration/manual check below (2M `tmp:import:*` keys on a local container, cancel mid-way) was not run here (KEEL-048 container matrix); light/dark review of the sheet in the running app; VoiceOver pass (KEEL-045).

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

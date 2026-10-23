# KEEL-023 · Key filters

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 3 pts | S6 | [KEEL-020](KEEL-020-scan-key-index.md) |

**Specs:** [FR-KB05](../03-functional-requirements.md#2-key-browser)

## Story

As a user, I want to filter by pattern and type, so that I can find keys like `user:*` hashes quickly.

## Scope

- Pattern field → `SCAN MATCH` (glob help popover); type filter → `SCAN TYPE` (client-side for module types)
- Quick local substring filter over loaded keys
- ⌘F focuses the filter

## Acceptance criteria

- [x] **AC1.** `user:*` + hash lists only hashes under `user:`.
- [x] **AC2.** Changing a filter restarts the scan and clears stale results.
- [x] **AC3.** Local filter over 1M keys returns first results < 150 ms.
- [x] **AC4.** Client-side type filtering says so.

### Verification notes

- AC1 observed in `KeyFilterTests.testPatternAndTypeBuildScanArguments` against a typed fake keyspace that honors `MATCH` and `TYPE`: every page is `SCAN … MATCH user:* COUNT 1000 TYPE hash`, only `user:1`, `user:3`, `user:6` load, no per-key `TYPE` is sent and the keys take the `hash` badge. Real servers (Redis 6.0–8.x, Valkey, Dragonfly) are **pending** with the `KeelIntegrationTests` matrix (KEEL-053).
- AC2 observed in `KeyFilterTests.testFilterChangeRestartsScan` / `testFilterChangeDropsThePageInFlight` and `KeyFilterModelTests.testChangingAFilterRestartsTheScan`: a new filter empties the list at once, the next SCAN starts at cursor 0 with the new arguments, a page of the old scan landing afterwards is dropped, and Refresh (`restart()`) keeps the filter (FR-KB09).
- AC3 observed in `LocalFilterPerformanceTests.testFirstResultsBudget` (release, `swift test -c release -Xswiftc -enable-testing`, Apple silicon, 1M keys): first results in 1.6–2.6 ms; a query matching nothing searches all 1M keys in ~7 ms. Debug builds (CI) guard at 5× the budget (~38 ms observed).
- AC4 observed in `KeyFilterTests.testModuleTypesFilteredClientSide` and `KeyFilterModelTests.testChangingAFilterRestartsTheScan`: "Other (module types)" sends SCAN without `TYPE`, checks each key with a pipelined `TYPE` (at most 256 in flight) and `KeyFilterModel.notice` carries the line the bar shows under the field. Seeing it on screen is **pending**: the key list pane is mounted in a window with KEEL-025/026.
- ⌘F is View → Filter Keys; it posts a notification with the key window and only that window's filter field takes focus (`testCommandFFocusesOnlyItsWindowsField`). Light/dark design review of the filter bar and a VoiceOver pass are **pending** until the pane is on screen.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `KeyFilterTests.testPatternAndTypeBuildScanArguments` | Pattern and type build scan arguments |
| `KeyFilterTests.testFilterChangeRestartsScan` | Filter change restarts scan |
| `KeyFilterTests.testModuleTypesFilteredClientSide` | Module types filtered client side |
| `LocalFilterPerformanceTests.testFirstResultsBudget` | First results budget |
| `KeyFilterTests` (extra) | Page in flight dropped on a filter change; failed TYPE check keeps the cursor; TYPE names; local query case and bytes |
| `KeyFilterReviewTests` | TYPE checks bounded at 256 in flight and complete; a failure stops sending; restart bumps the generation |
| `KeyFilterModelTests` / `KeyFilterModelReviewTests` (`KeelUITests`) | Local matches shown flat in either mode; keys loaded later searched; restarts start the local search over; filter changes restart the scan; ⌘F targets its window |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

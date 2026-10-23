# KEEL-025 · Database switcher, DBSIZE and refresh

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 2 pts | S4 | [KEEL-020](KEEL-020-scan-key-index.md) |

**Specs:** [FR-KB08, FR-KB09, FR-KB12](../03-functional-requirements.md#2-key-browser)

## Story

As a user, I want to switch databases and refresh with accurate counts, so that I always see the current state.

## Scope

- Toolbar db picker (db0–db15 or `databases` count) with counts from `INFO keyspace`; ⌥⌘0–9
- ⌘R refresh keeps filters and selection when possible; DBSIZE for the footer
- Missing key → "Key no longer exists"

## Acceptance criteria

- [x] **AC1.** Databases with keys show their counts; cluster servers offer db0 only.
- [x] **AC2.** After another client adds a key, ⌘R shows it and DBSIZE increments.
- [x] **AC3.** Opening a deleted key shows the message and offers removal from the list.

### Verification notes

- AC1 observed in `DatabaseListTests.testCountsFromInfoKeyspace` (`INFO keyspace` lines with and without `subexpiry` give "db0 · 1,204 keys" / "db3 · 1 key", empty databases their name alone; db0–db15 without the server's count, the `CONFIG GET databases` count when known, bounded at 4,096; one `INFO keyspace` on the browser connection of a read-only profile), `testClusterOffersDb0Only` and `testDatabaseCountFromConfigGet` (RESP2/RESP3 replies, `NOPERM` and a failed probe fall back to db0–db15). `BrowserModelTests.testSwitchingDatabaseClearsTheListAndOnlyOffersKnownDatabases` shows the picker's counts, a switch that clears the list and selection and scans the new database on its own browser connection, and that db16 (unknown count) and db1 on a cluster are not offered.
- AC2 observed against in-memory fake servers: `RefreshTests.testKeepsFilterAndSelection` (a key added by "another client" appears after Refresh with the same `MATCH`/`TYPE`, `DBSIZE` goes 4 → 5, the selected key is found again by its bytes at its new index, no `KEYS`) and `BrowserModelTests.testRefreshShowsNewKeysWithDbsizeAndKeepsSelection` (the footer's total goes 3 → 4 and the same key is selected after ⌘R although its row moved).
- AC3 observed in `MissingKeyTests.testReportsAndOffersRemoval` (one `TYPE` reports the deleted key missing and marks its row stale/gone; Remove from List sends nothing, shifts later keys with their metadata, updates tree counts and bumps the generation), `testCheckFailureLeavesTheKeyAlone`, `testRemovalDuringAScanKeepsTheScanGoing`, and `BrowserModelTests.testOpeningADeletedKeyOffersRemoval` (selecting the key raises "Key no longer exists", another selection hides it, removal drops only that row).
- Review: `DatabaseSwitchReviewTests` covers a `TYPE` that lands after a switch (the new database's row stays untouched), a removal while a page is in flight, and a recreated key that stops reading "expired".
- **Pending:** observing the picker, ⌘R and ⌥⌘0–9 in the running app — the browser isn't hosted in a tab yet (KEEL-026 puts `DatabasePicker` in the toolbar and `BrowserPane` in the tab and runs `DatabaseList.probeCount` at session setup); the protocol trace on real servers (Redis 6.0–8.x, Valkey 7.2–9.x, Dragonfly, an ACL user without `CONFIG`, a cluster node) with `KeelIntegrationTests` (KEEL-053); VoiceOver pass and light/dark review of the picker and the notice.

## Unit tests

Test target: `KeelCoreTests` (plus `KeelUITests.BrowserModelTests`).

| Test | Verifies |
| --- | --- |
| `DatabaseListTests.testCountsFromInfoKeyspace` | Counts from info keyspace |
| `DatabaseListTests.testClusterOffersDb0Only` | Cluster offers db0 only |
| `RefreshTests.testKeepsFilterAndSelection` | Keeps filter and selection |
| `MissingKeyTests.testReportsAndOffersRemoval` | Reports and offers removal |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

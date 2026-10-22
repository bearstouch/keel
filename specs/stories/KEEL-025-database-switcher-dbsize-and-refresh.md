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

- [ ] **AC1.** Databases with keys show their counts; cluster servers offer db0 only.
- [ ] **AC2.** After another client adds a key, ⌘R shows it and DBSIZE increments.
- [ ] **AC3.** Opening a deleted key shows the message and offers removal from the list.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `DatabaseListTests.testCountsFromInfoKeyspace` | Counts from info keyspace |
| `DatabaseListTests.testClusterOffersDb0Only` | Cluster offers db0 only |
| `RefreshTests.testKeepsFilterAndSelection` | Keeps filter and selection |
| `MissingKeyTests.testReportsAndOffersRemoval` | Reports and offers removal |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

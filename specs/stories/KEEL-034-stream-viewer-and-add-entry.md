# KEEL-034 · Stream viewer and add entry

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S6 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md), [KEEL-011](KEEL-011-server-detection-capability-probes-and-minimum-version.md) |

**Specs:** [FR-ED06](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to read stream entries and append new ones, so that I can debug event streams.

## Scope

- `XREVRANGE`/`XRANGE` pages of 500 (newest first), exclusive ranges or ID increment on 6.0/6.1
- `XLEN`, `XINFO STREAM` summary in Details; Add entry sheet (`*` or explicit ID) via `XADD`

## Acceptance criteria

- [ ] **AC1.** Paging never repeats or skips an entry.
- [ ] **AC2.** Adding with `*` shows the server-assigned ID at the top.
- [ ] **AC3.** Entries are read-only (XDEL is P1).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `StreamViewerTests.testPagingWithoutDuplicates` | 6.0 and 6.2 paths |
| `StreamViewerTests.testIdIncrementFallback` | Id increment fallback |
| `StreamViewerTests.testAddEntryBuildsXAdd` | Add entry builds xadd |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

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

- [x] **AC1.** Paging never repeats or skips an entry.
- [x] **AC2.** Adding with `*` shows the server-assigned ID at the top.
- [x] **AC3.** Entries are read-only (XDEL is P1).

### Verification notes

- AC1 observed in `StreamViewerTests.testPagingWithoutDuplicates` (1,235 entries, three per millisecond, in an in-memory server: newest first and oldest first each return every ID exactly once, in order, on a 6.2+ server with `(id` bounds and on a 6.0 server that refuses them, where the page after `1245-0` starts at `1244-18446744073709551615`; the probe runs once per session) and `testIdIncrementFallback` (sequence and millisecond carries both ways, nothing read past `0-0` or the largest ID).
- AC2 observed in `StreamEditorSessionTests.testAutoIDEntryShowsAtTop` (KeelUITests: after toggling to oldest first, `XADD events * type login` puts `1700000000000-0` at the top, selected, with its value read-only in the viewer; `XLEN` goes to 4) and `StreamViewerTests.testAddEntryBuildsXAdd` (auto and explicit IDs, bytes kept exactly; a smaller explicit ID is the server's error and adds nothing).
- AC3 observed in `StreamViewerTests.testEntriesAreReadOnly` (a save writes nothing for any draft, never `XDEL`; the viewer doesn't edit) and `testInvalidInputAndReadOnlySendNothing` (a read-only profile can't add and sends no `XADD`).
- Details: `testStreamSummaryInDetails` (`XINFO STREAM` as RESP2 array and RESP3 map). Seeing the viewer in the running app, light and dark, a VoiceOver pass and paging against real Redis 6.0 / 6.2 / 7.x / Valkey containers (KEEL-048) are **pending**.
- Review fixes: an explicit ID must start with a digit, so a typed `MAXLEN` / `MINID` / `NOMKSTREAM` can't turn the `XADD` into a trim (`StreamEditorReviewTests.testExplicitIDCannotBeAnXAddOption`); a failed add keeps the paged order it was loaded in (`testFailedReadBackKeepsPageOrder`); `StringEditorTests.testOnlyBuiltEditorsAreOffered` now expects a stream editor.
- Follow-ups: `CapabilitySet.xrangeAfter` still sends `(max-max` in exclusive mode (unused by the viewer, pre-existing); a selected ID that the read-back didn't return stays set (hidden); the viewer keeps a dropped entry's bytes (hidden); packed fields are re-parsed per render; loaded rows aren't capped (as in the other editors).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `StreamViewerTests.testPagingWithoutDuplicates` | 6.0 and 6.2 paths |
| `StreamViewerTests.testIdIncrementFallback` | Id increment fallback |
| `StreamViewerTests.testAddEntryBuildsXAdd` | Add entry builds xadd |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

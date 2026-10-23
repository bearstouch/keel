# KEEL-029 · String editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S5 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [FR-ED01](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to view and edit strings, including large ones, safely, so that I can fix values without truncating them.

## Scope

- Full load ≤ 1 MiB; larger: first 1 MiB via `GETRANGE`, "Load all" up to 64 MiB; editing disabled for partial loads
- Save with `SET … KEEPTTL` inside WATCH/MULTI

## Acceptance criteria

- [x] **AC1.** A 2 MiB string shows "Partial (1 MiB of 2 MiB)" with editing disabled until fully loaded.
- [x] **AC2.** Saving keeps the TTL.
- [x] **AC3.** Saving an unchanged value sends nothing.

### Verification notes

- AC1 observed in `StringEditorTests.testPartialLoadDisablesEditing` (a 2 MiB value sends `STRLEN` + `GETRANGE blob 0 1048575`, never `GET`; `PartialLoad.text` is "Partial (1 MiB of 2 MiB)"; "Load all" reads it whole) and `StringEditorSessionTests.testPartialLoadIsReadOnlyUntilLoadAll` (viewer not editable, edits and Save refused and nothing written until "Load all", then editable and saved). Over 64 MiB "Load all" is refused before any `GET` (`testOverLimitIsNotLoadedWhole`). Seeing the notice in the running app, in light and dark, and a VoiceOver pass are **pending**.
- AC2 observed in `StringEditorTests.testSaveKeepsTTL`: `WATCH`, `GET`, `MULTI`, `SET blob new KEEPTTL`, `EXEC`, and the fake server's 60 s TTL survives (it drops TTLs on `SET` without `KEEPTTL`).
- AC3 observed in `StringEditorTests.testNoOpSaveSendsNothing` (no writes, nothing sent) and `StringEditorSessionTests.testUnchangedSaveSendsNothing`.
- Review fix: a save's read-back (and the re-read after an unknown outcome) reads the whole value, so saving a value over 1 MiB keeps it editable instead of reopening it as a partial first page (`StringEditorSessionReviewTests`).
- Follow-ups: cap the draft size at the 64 MiB load limit before Save; Reload after a conflict reopens a large value partially; `PartialLoad.binary` shows 1,048,575 bytes as "1024 KiB"; an unguarded Reload during "Load all" lets the later read win.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `StringEditorTests.testPartialLoadDisablesEditing` | Partial load disables editing |
| `StringEditorTests.testSaveKeepsTTL` | KEEPTTL in command |
| `StringEditorTests.testNoOpSaveSendsNothing` | No op save sends nothing |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

# KEEL-035 · Key actions: rename, TTL, delete, export

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S6 | [KEEL-027](KEEL-027-editor-shell-save-bar-and-conflicts.md) |

**Specs:** [FR-ED10–FR-ED12, FR-ED15](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to rename keys, change TTLs, delete and export values from the ⋯ menu, so that common maintenance is quick and safe.

## Scope

- Rename with `RENAMENX`, overwrite confirmation → `RENAME`
- TTL presets, custom duration, absolute date (`PEXPIRE`/`PEXPIREAT`), Persist; absolute expiry via `PEXPIRETIME` or computed
- Delete single key with `UNLINK` and a normal confirmation
- Export value to file (raw bytes or JSON for collections); copy value

## Acceptance criteria

- [x] **AC1.** Renaming onto an existing key without confirming changes nothing.
- [x] **AC2.** Setting TTL to 1 h shows the expiry clock time; Persist shows no expiry.
- [x] **AC3.** Exporting a binary string writes identical bytes.

### Verification notes

- AC1 observed in `KeyActionsTests.testRenameOverwriteRequiresConfirmation` (in-memory server: `RENAMENX` replies 0, both keys keep their values and no `RENAME` is sent; a confirmation for another target is refused with nothing sent; the confirmed `RENAME` replaces the target) and `KeyActionsSessionTests.testRenameSelectsTheNewNameAndOverwriteAsksFirst` (KeelUITests: the editor stays open on the old key until Replace; a plain rename reopens the editor on the new name and the list holds it).
- AC2 observed in `KeyActionsTests.testTTLPresetsAndAbsolute` (1 h → `PEXPIRE k 3600000`, then `PEXPIRETIME`; the expiry reads `1/15/2027, 9:00:00 AM` in a fixed UTC style; on a server without `PEXPIRETIME` the time is now + `PTTL`; `PEXPIREAT` for a date; zero, negative and past times send nothing) and `testPersistRemovesTTL` (`PERSIST`, expiry `—`). It is observed at the model level; the Set TTL sheet in the running app is **pending**.
- AC3 observed in `ValueExportTests.testBinaryExportIsByteExact` (all 256 byte values plus invalid UTF-8 written to a file and read back identical, `.bin` suggested). `KeyActionsSessionTests.testExportUsesTheLoadedValueOnlyWhenWhole`: a partial 2 MiB string or a paged hash can't be exported.
- Delete: `testDeleteUsesUnlinkForOneKey`, `KeyActionsSessionTests.testDeleteRemovesKeyAndShowsEmptyEditor` (the key leaves the list, the editor closes, the total goes down by one). Read-only: `testReadOnlyProfileSendsNothing`, `testReadOnlyProfileBlocksKeyActions`.
- Review fix: a rename onto a loaded key resets that row's metadata (TTL, size, stale mark) and bumps the generation, so answers read for the replaced key are dropped (`KeyActionsReviewTests.testAddOntoLoadedKeyResetsItsMetadata`).
- Pending: the sheets, the save panel and the ⋯ menu seen in the running app in light and dark; a VoiceOver pass; real Redis 6.0 / 7.x and Valkey containers (KEEL-048). ⌘⌫ isn't bound to Delete here (as a menu shortcut it would catch ⌘⌫ in the value editor); it arrives with the key list's multi-key delete in KEEL-038.
- Follow-ups (from review, not applied): `BrowserModel.keyChanged` doesn't check whether the selection or database changed while it awaits; `KeyIndex.add` ignores the key limit and the local filter; export stays disabled without a clear reason when the header's length couldn't be read; the total can be off by one after a replacing rename if the target was deleted elsewhere; a lost TTL reply shows the generic error rather than the unknown-outcome message (the expiry is re-read); the date picker's lower bound is set when the sheet renders.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `KeyActionsTests.testRenameUsesRenameNX` | Rename uses rename nx |
| `KeyActionsTests.testRenameOverwriteRequiresConfirmation` | Rename overwrite requires confirmation |
| `KeyActionsTests.testTTLPresetsAndAbsolute` | Ttlpresets and absolute |
| `KeyActionsTests.testPersistRemovesTTL` | Persist removes TTL |
| `ValueExportTests.testBinaryExportIsByteExact` | Binary export is byte exact |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

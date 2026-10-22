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

- [ ] **AC1.** Renaming onto an existing key without confirming changes nothing.
- [ ] **AC2.** Setting TTL to 1 h shows the expiry clock time; Persist shows no expiry.
- [ ] **AC3.** Exporting a binary string writes identical bytes.

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

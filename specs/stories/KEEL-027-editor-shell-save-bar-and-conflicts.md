# KEEL-027 · Editor shell, save bar and conflicts

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 5 pts | S5 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md), [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md) |

**Specs:** [03 → Value editors common rules](../03-functional-requirements.md#3-value-editors), [FR-ED13](../03-functional-requirements.md#3-value-editors), [08 Design → Editor](../08-design.md#editor)

## Story

As a user, I want a calm editor with one metadata line, actions in ⋯ and a save bar only when I change something, so that editing is clear and safe.

## Scope

- Header: key (mono), type badge, ⋯ (Rename, Set TTL, Copy, Delete, Details); metadata line "Expires in 3 days · 6 fields"
- Floating save bar ("1 unsaved change · Revert · Save"), ⌘S / ⌘Z, changed-row dot
- Whole-value saves with `WATCH` + `MULTI/EXEC`; `CONFLICT` offers Reload / Overwrite
- Read-only view: lock + "Read-only" in metadata, no add/save, write actions disabled

## Acceptance criteria

- [x] **AC1.** The save bar appears only while there are unsaved changes.
- [x] **AC2.** A concurrent change between load and save reports `CONFLICT`; nothing is overwritten unless the user chooses Overwrite.
- [x] **AC3.** Read-only profiles show no Save or Add controls and send no writes.
- [x] **AC4.** Details shows encoding, exact TTL and memory size on request, or "unavailable".

### Verification notes

- AC1 observed in `EditorSessionTests.testDirtyStateDrivesSaveBar`: no bar after loading, "1 unsaved change" after an edit, gone when the loaded value is typed back and after a save (trace `WATCH, GET, MULTI, SET … KEEPTTL, EXEC`).
- AC2 observed in `testWatchConflictReported` (another client's change before the save: `CONFLICT`, `UNWATCH`, no `MULTI`, the other value kept, the draft kept; Reload takes the server's value) and `testChangeAfterGuardReadIsConflictAndOverwriteWins` (a change between the guard read and `EXEC`: nil `EXEC` → `CONFLICT`, nothing written; Overwrite then writes). `RedisPipelineTests` show `MULTI … EXEC` leaves as one write.
- AC3 observed in `testReadOnlyDisablesWrites` (no save bar, `allowsWrites` false, "· Read-only" in the metadata line, no `WATCH`/`MULTI`/`SET`/`EXEC` in the trace, the service refuses with `READ_ONLY` and sends nothing) and `EditorTransactionTests.testRefusedWriteSendsNothing`.
- AC4 observed in `KeyDetailsTests` (`OBJECT` unknown and `MEMORY` `NOPERM` → "unavailable"; encoding, "90,000 ms (1m 30s)" and memory only after Measure; a gone key → "unavailable").
- Review: `EditorTransactionReviewTests.testCancelledGuardedSaveDropsItsWatch` (a cancelled save never leaves a `WATCH` on the shared browser connection); the editor never stays open on the same key name from another database.
- **Pending:** the shell in the running app and its design review in light and dark against `Main` (not done in this environment); VoiceOver pass of the header, ⋯ menu and save bar. No type editor exists yet (KEEL-029…034 supply `EditorBinding`s), so the save bar, ⌘S / ⌘Z and the conflict alert can't be exercised in the app yet; Rename, Set TTL and Delete in ⋯ stay disabled until KEEL-035. KEEL-026 AC3 (closing with unsaved edits) remains pending for the same reason.
- Follow-ups for KEEL-029+: changing the selection, switching database or disconnecting drops a draft without asking; ⌘Z is File → Revert Changes and there is no Edit menu yet (text-field undo); after an `EXEC` where one write failed, re-read the value as the outcome-unknown path does.

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `EditorSessionTests.testDirtyStateDrivesSaveBar` | Dirty state drives save bar |
| `EditorSessionTests.testWatchConflictReported` | fake server changes key |
| `EditorSessionTests.testRevertRestoresLoadedValue` | Revert restores loaded value |
| `EditorSessionTests.testReadOnlyDisablesWrites` | Read only disables writes |
| `KeyDetailsTests.testUnavailableWhenUnsupported` | Unavailable when unsupported |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

# KEEL-037 · Read-only mode and production chrome

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S5 | [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md), [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md) |

**Specs:** [FR-SF01, FR-SF02, FR-SF07](../03-functional-requirements.md#5-safety), [08 Design → Production strip](../08-design.md#production-strip)

## Story

As an operator, I want production connections to look different and be read-only when I say so, so that I can't change production by accident.

## Scope

- Read-only toggle per profile; turning it off on a Production-labeled profile asks first
- 28 px maroon strip "Production · Read-only" under the tab bar; Window menu "[PROD]"
- "Writing to PRODUCTION" notice the first time per tab on writable production profiles
- Server-enforced read-only shown when the ACL user can't write

## Acceptance criteria

- [x] **AC1.** The strip appears only for production tabs in the frontmost window, with text, in both themes.
- [x] **AC2.** Turning read-only off on Production requires confirmation.
- [x] **AC3.** A protocol trace of every editor action on read-only shows nothing sent.

### Verification notes

- AC1 observed at the model level in `ProductionChromeTests.testStripVisibilityFollowsTab` (no tab → no strip; a Production read-only tab → "Production · Read-only"; selecting a non-production or read-only-only tab removes it; a writable Production tab → "Production"; a label marked treat-as-production shows it) and `testStripContrast` (text ≥ 4.5:1 on `prodStrip` in light and dark; in light the strip is ≥ 3:1 against the tab bar and content; it is darker than the accent). `testTurningReadOnlyOnLocksOpenTabs` and `testServerRefusalShowsServerEnforcedReadOnly` show the strip following what the connected session enforces. The strip in the running app, in light and dark, is **pending**.
- AC2 observed in `ProductionChromeTests.testDisablingReadOnlyAsks` (the switch stays on until Allow Writes; Keep Read-only leaves it on; a non-production profile isn't asked; a writable profile given the Production label asks on Save and nothing is saved until Yes; an already writable production profile saves a rename without asking). The alert in the running app is **pending**.
- AC3 observed in `ReadOnlyTraceTests.testEveryEditorActionSendsNothingOnReadOnly` (string, hash, list, set, sorted set and stream editors on a read-only profile: every edit, add, remove, push/pop/insert, score change, increment, stream add, save, overwrite, immediate write, rename, TTL and delete; every traced command is a read) and `testDataPathRefusesEveryWriteOnReadOnly` (every write operation, single and in a save, with and without a confirmation: `READ_ONLY`, nothing reaches the server).
- Also: `testWindowTitleMarksProd` ("payments-prod [PROD]", "Keel" without tabs), `testWritingToProductionNoticeShowsOncePerTab` / `testNoNoticeOutsideWritableProduction` (FR-SF07), `ReadOnlyModeTests` and `ReadOnlyModeReviewTests` (the session lock covers single commands, saves and a save already past its first check; write events; `NOPERM … permissions to run` on a data write and `READONLY` mean server-enforced read-only, admin or key-pattern refusals don't).
- Pending: the "[PROD]" title in the Window menu of the running app; a VoiceOver pass over the strip and the notice; the console's banner arrives with the console (KEEL-041); real servers with ACL users and read-only replicas (KEEL-048).
- Follow-ups (from review, not applied): server-enforced read-only lasts for the session even if the ACL is relaxed; a single command already past the policy when the lock lands may still be sent; after one Allow Writes the sheet doesn't ask again; the sheet's production-label lookup duplicates `ConnectionsDocument.label(_:)`; profile watching starts in `AppModel.restore()`; after a lock the open editor still offers edits (the data path refuses them) until reconnect; `testLockDuringGuardReadSendsNoWrite` blocks one cooperative thread for up to 5 s.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ProductionChromeTests.testStripVisibilityFollowsTab` | Strip visibility follows tab |
| `ProductionChromeTests.testDisablingReadOnlyAsks` | Disabling read only asks |
| `ProductionChromeTests.testWindowTitleMarksProd` | Window title marks prod |
| `ProductionChromeTests.testStripContrast` | ≥ 3:1 / text 4.5:1 |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

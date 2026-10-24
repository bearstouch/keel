# KEEL-036 · New key sheet

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 3 pts | S6 | [KEEL-029](KEEL-029-string-editor.md), [KEEL-030](KEEL-030-hash-editor.md), [KEEL-031](KEEL-031-list-editor.md), [KEEL-032](KEEL-032-set-editor.md), [KEEL-033](KEEL-033-sorted-set-editor.md), [KEEL-034](KEEL-034-stream-viewer-and-add-entry.md) |

**Specs:** [FR-ED14](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to create a key of any type with its first value and an optional TTL, so that I can seed data quickly.

## Scope

- ⇧⌘N sheet: name prefilled with the selected namespace + separator, type picker, first value(s), TTL
- Create-only semantics (`SET NX`; EXISTS inside WATCH/MULTI for other types)

## Acceptance criteria

- [x] **AC1.** Creating an existing key shows "Key already exists" and creates nothing.
- [x] **AC2.** The new key is selected after creation.
- [x] **AC3.** The sheet is blocked on read-only profiles.

### Verification notes

- AC1 observed in `NewKeyTests.testCreateOnlySemanticsPerType` (in-memory server, every type: a string is one `SET … NX`, the others `WATCH` + `EXISTS` + `MULTI/EXEC`; an existing key of any type is left as it was and no write is sent; a key that appears between `WATCH` and `EXEC` runs nothing and reads back as "exists") and `NewKeySessionTests.testExistingKeySaysSoAndCreatesNothing` (KeelUITests: "Key already exists", list and total unchanged).
- AC2 observed in `NewKeySessionTests.testCreatedKeyIsSelected` (the key joins the list, is selected and opens in the editor; the total goes up by one). Observed at the model level; the sheet in the running app is **pending**.
- AC3 observed in `NewKeyTests.testBlockedOnReadOnly` (`READ_ONLY`, nothing sent, for a string, a hash and a stream with a TTL) and `NewKeySessionTests.testReadOnlyProfileBlocksTheSheet` (`canCreateKey` is false, which disables Key → New Key… and ⇧⌘N; a create sends nothing). The disabled menu item in the running app is **pending**.
- Also: `testTTLAppliesWithTheValue` (`SET … NX PX`, or `PEXPIRE` in the same `EXEC`), `testInvalidInputIsRefusedBeforeSending`, `testServerErrorInsideExecIsReported`, `testPrefillsNamespace`.
- Pending: the sheet seen in the running app in light and dark; a VoiceOver pass; real Redis 6.0 / 7.x, Valkey and Dragonfly containers (KEEL-048).
- Follow-ups (from review, not applied): a list or set whose single row is left empty creates one empty element; after an unknown outcome a retry says "Key already exists" for the user's own key; a key that appears and vanishes before the re-read shows the generic conflict message; in the flat view a selected key doesn't prefill its namespace (only the tree does, as FR-ED14 now says).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `NewKeyTests.testCreateOnlySemanticsPerType` | Create only semantics per type |
| `NewKeyTests.testPrefillsNamespace` | Prefills namespace |
| `NewKeyTests.testBlockedOnReadOnly` | Blocked on read only |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

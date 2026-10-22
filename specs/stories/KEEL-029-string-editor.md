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

- [ ] **AC1.** A 2 MiB string shows "Partial (1 MiB of 2 MiB)" with editing disabled until fully loaded.
- [ ] **AC2.** Saving keeps the TTL.
- [ ] **AC3.** Saving an unchanged value sends nothing.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `StringEditorTests.testPartialLoadDisablesEditing` | Partial load disables editing |
| `StringEditorTests.testSaveKeepsTTL` | KEEPTTL in command |
| `StringEditorTests.testNoOpSaveSendsNothing` | No op save sends nothing |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

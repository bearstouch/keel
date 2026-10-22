# KEEL-032 · Set editor

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E4 Editors and safety | P0 | 2 pts | S6 | [KEEL-028](KEEL-028-value-viewers-text-json-hex-raw.md) |

**Specs:** [FR-ED04](../03-functional-requirements.md#3-value-editors)

## Story

As a user, I want to browse, add and remove set members, so that I can maintain flags and memberships.

## Scope

- `SMEMBERS` when `SCARD` ≤ 1,000 else `SSCAN`; add `SADD`, remove `SREM`; local filter; count

## Acceptance criteria

- [ ] **AC1.** Adding an existing member reports "already a member".
- [ ] **AC2.** Large sets page with SSCAN.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `SetEditorTests.testChoosesSMembersOrSScan` | Chooses smembers or sscan |
| `SetEditorTests.testAddExistingReportsAlreadyMember` | Add existing reports already member |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

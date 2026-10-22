# KEEL-023 · Key filters

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 3 pts | S6 | [KEEL-020](KEEL-020-scan-key-index.md) |

**Specs:** [FR-KB05](../03-functional-requirements.md#2-key-browser)

## Story

As a user, I want to filter by pattern and type, so that I can find keys like `user:*` hashes quickly.

## Scope

- Pattern field → `SCAN MATCH` (glob help popover); type filter → `SCAN TYPE` (client-side for module types)
- Quick local substring filter over loaded keys
- ⌘F focuses the filter

## Acceptance criteria

- [ ] **AC1.** `user:*` + hash lists only hashes under `user:`.
- [ ] **AC2.** Changing a filter restarts the scan and clears stale results.
- [ ] **AC3.** Local filter over 1M keys returns first results < 150 ms.
- [ ] **AC4.** Client-side type filtering says so.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `KeyFilterTests.testPatternAndTypeBuildScanArguments` | Pattern and type build scan arguments |
| `KeyFilterTests.testFilterChangeRestartsScan` | Filter change restarts scan |
| `KeyFilterTests.testModuleTypesFilteredClientSide` | Module types filtered client side |
| `LocalFilterPerformanceTests.testFirstResultsBudget` | First results budget |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

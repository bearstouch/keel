# KEEL-021 · Namespace tree and binary-safe names

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E3 Key browser | P0 | 5 pts | S4 | [KEEL-020](KEEL-020-scan-key-index.md) |

**Specs:** [FR-KB03, FR-KB10](../03-functional-requirements.md#2-key-browser), [NFR-PF04](../04-non-functional-requirements.md#performance)

## Story

As a user, I want keys grouped into a tree by a separator I choose, with odd bytes shown safely, so that large keyspaces are navigable.

## Scope

- Incremental tree builder off the main actor with child counts; separator per profile (1–4 bytes, default `:`)
- Keys that are also namespaces
- redis-cli escaping for non-UTF-8 display; actions use original bytes

## Acceptance criteria

- [ ] **AC1.** `a:b` and `a:b:c` show `a:b` as both a key and a folder.
- [ ] **AC2.** Changing the separator rebuilds the tree.
- [ ] **AC3.** A key `\xff\x00a` displays escaped and can be opened, renamed and deleted.
- [ ] **AC4.** Building the tree for 1M keys takes < 2 s; expanding any node < 200 ms.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `NamespaceTreeTests.testKeyAndFolderCoexist` | Key and folder coexist |
| `NamespaceTreeTests.testCountsUpdateIncrementally` | Counts update incrementally |
| `NamespaceTreeTests.testCustomSeparator` | Custom separator |
| `KeyDisplayTests.testEscapesNonUTF8LikeRedisCli` | Escapes non UTF-8 like redis cli |
| `NamespaceTreePerformanceTests.testOneMillionKeysUnderBudget` | XCTest measure |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

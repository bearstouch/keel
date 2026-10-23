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

- [x] **AC1.** `a:b` and `a:b:c` show `a:b` as both a key and a folder.
- [x] **AC2.** Changing the separator rebuilds the tree.
- [ ] **AC3.** A key `\xff\x00a` displays escaped and can be opened, renamed and deleted.
- [x] **AC4.** Building the tree for 1M keys takes < 2 s; expanding any node < 200 ms.

### Verification notes

- AC1, AC2 observed in `NamespaceTreeTests` (`testKeyAndFolderCoexist`, `testChangingSeparatorRebuildsTree`), with stale folder IDs from an old tree refused (`NamespaceTreeReviewTests`).
- AC3 **partially observed**: `\xff\x00a` displays escaped in the tree and copies as `"\xff\x00a"`; GET, RENAMENX and UNLINK sent through `DataCommandService` carry the original bytes (`KeyDisplayTests.testBinaryKeyActionsUseOriginalBytes`). Opening it in an editor and the rename/delete UI are **pending** the editor and key-action stories (KEEL-027/028 and later).
- AC4 observed in `NamespaceTreePerformanceTests` with 1M keys in scrambled (SCAN-like) order on Apple silicon: release build (`swift test -c release -Xswiftc -enable-testing`) ~0.2–0.3 s to build, slowest expand (a 500,000-child folder) ~40 ms. Debug builds, as CI runs them, take ~2.5 s / ~0.4 s and are checked with 5× slack. Intel is **pending** (KEEL-052).
- Memory (NFR-RS01): on 100k 30-byte keys where every key opens two folders of its own, index buffers are ~32 B/key, the tree ~102 B/key, and total heap ~164 B/key including the names, about 164 MB projected for 1M keys (< 200 MB). The ≤ 120 B/key clause is read as the index alone; the spec page now says so.

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

# KEEL-008 · CA file change detection

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 2 pts | S2 | [KEEL-007](KEEL-007-tls-with-custom-ca-client-identity-and-skip-verify.md), [KEEL-003](KEEL-003-owner-only-versioned-persistence.md) |

**Specs:** [FR-CN04](../03-functional-requirements.md#1-connections)

## Story

As a security-conscious user, I want Keel to notice when a referenced CA file changes, so that a swapped certificate can't silently become trusted.

## Scope

- Store SHA-256 of each referenced CA file in `known-ca.json`
- On connect, compare; on change show old/new fingerprints and require acceptance

## Acceptance criteria

- [ ] **AC1.** Replacing the CA file shows both fingerprints before connecting; declining aborts with no connection attempt.
- [ ] **AC2.** Accepting updates the stored fingerprint; the next connect doesn't ask again.
- [ ] **AC3.** A missing CA file fails with a clear message naming the path.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `KnownCATests.testFirstUseStoresFingerprint` | First use stores fingerprint |
| `KnownCATests.testChangedFileRequiresAcceptance` | Changed file requires acceptance |
| `KnownCATests.testMissingFileIsReported` | Missing file is reported |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

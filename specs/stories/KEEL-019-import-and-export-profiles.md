# KEEL-019 · Import and export profiles

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 3 pts | S8 | [KEEL-014](KEEL-014-connection-profiles-and-keychain-secrets.md) |

**Specs:** [FR-CN14](../03-functional-requirements.md#1-connections), [INT-12](../06-integrations.md#import-and-export)

## Story

As a user, I want to export and import my profiles without secrets, so that I can move them to another Mac or share them safely.

## Scope

- Versioned JSON export of profiles and folders (no secrets, no `hasPassword`)
- Import preview with counts and conflicts; collision policies Skip / Replace / Keep both

## Acceptance criteria

- [ ] **AC1.** An export contains no password, passphrase, token or `hasPassword`.
- [ ] **AC2.** Re-importing with Skip changes nothing.
- [ ] **AC3.** Import is atomic: a failure leaves profiles untouched.
- [ ] **AC4.** Newer export versions are refused with a clear message.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ProfileExportTests.testExportHasNoSecretFields` | Export has no secret fields |
| `ProfileImportTests.testSkipPolicyIsIdempotent` | Skip policy is idempotent |
| `ProfileImportTests.testFailedImportIsAtomic` | Failed import is atomic |
| `ProfileImportTests.testRejectsNewerVersion` | Rejects newer version |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

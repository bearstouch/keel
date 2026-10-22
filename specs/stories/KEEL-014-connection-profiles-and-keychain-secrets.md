# KEEL-014 · Connection profiles and Keychain secrets

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 5 pts | S2 | [KEEL-003](KEEL-003-owner-only-versioned-persistence.md) |

**Specs:** [FR-CN01, FR-CN02, FR-CN09](../03-functional-requirements.md#1-connections), [02 Architecture → Keychain items](../02-architecture.md#keychain-items)

## Story

As a user, I want to save connection profiles whose passwords live only in the Keychain, so that my connections persist without secrets on disk.

## Scope

- `ConnectionProfile` (name, label, host/port, username, db, TLS, tunnel, read-only, timeouts, separator, SETNAME) and `Folder`; `ProfileStore` actor with revisions
- `SecretStore` over the Keychain (`Keel Connection`, `Keel TLS`), written before metadata with rollback
- Connection-revision binding: host/port/user/SNI/tunnel change removes the saved password
- Color labels with editable names; built-in Production label

## Acceptance criteria

- [ ] **AC1.** Create, edit, duplicate, delete and reorder profiles; they survive relaunch.
- [ ] **AC2.** `connections.json` contains no password, passphrase or token — only `hasPassword` flags.
- [ ] **AC3.** A failed metadata write restores the previous Keychain value.
- [ ] **AC4.** Changing the host removes the saved password; renaming keeps it.
- [ ] **AC5.** Deleting a profile removes its Keychain items.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ProfileStoreTests.testCrudAndOrderPersist` | Crud and order persist |
| `ProfileStoreTests.testRevisionsRejectStaleUpdates` | Revisions reject stale updates |
| `SecretStoreTests.testKeychainWrittenBeforeMetadataWithRollback` | injected Keychain + failing persistence |
| `SecretStoreTests.testConnectionRevisionChangeDeletesPassword` | Connection revision change deletes password |
| `ProfileCodecTests.testEncodedFileHasNoSecrets` | byte scan of encoded JSON |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

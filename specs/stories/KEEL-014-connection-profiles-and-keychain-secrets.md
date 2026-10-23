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

- [x] **AC1.** Create, edit, duplicate, delete and reorder profiles; they survive relaunch.
- [x] **AC2.** `connections.json` contains no password, passphrase or token — only `hasPassword` flags.
- [x] **AC3.** A failed metadata write restores the previous Keychain value.
- [x] **AC4.** Changing the host removes the saved password; renaming keeps it.
- [x] **AC5.** Deleting a profile removes its Keychain items.

**Verification (KEEL-014).** AC1–AC5 observed in `ProfileStoreTests`, `SecretStoreTests` and `ProfileCodecTests`, using an
injected in-memory Keychain and `Persistence` with a failing write hook.
- AC1: CRUD, duplicate, folder moves and order reload equal in a fresh store over the same folder. "Survive relaunch"
  is observed at the store level; the editor and sidebar arrive with KEEL-016/017.
- AC3 covers update, password removal, host change, create, delete and the TLS item; a Keychain failure writes no metadata.
- AC4 also covers port, username, TLS server name and tunnel changes, and stale connection-revision lookups.
- Pending: `KeychainSecretStore` against the real login Keychain (no throwaway-keychain hook yet; tests never touch
  the user's Keychain). Wiring `TLSIdentityImporter` writes through `ProfileStore.setTLSSecret` is left to KEEL-016.

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

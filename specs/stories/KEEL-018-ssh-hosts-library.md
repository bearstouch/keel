# KEEL-018 · SSH hosts library

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 3 pts | S3 | [KEEL-010](KEEL-010-askpass-broker-and-ssh-prompt-relay.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [FR-CN06](../03-functional-requirements.md#1-connections), [INT-06](../06-integrations.md#ssh-tunnels)

## Story

As an operator, I want to pick an SSH host from my `~/.ssh/config` or Keel's saved hosts, with an optional Keychain password, so that tunnels are easy to configure.

## Scope

- Keel-owned `hosts.json` via vendored `HostLibrary`; `SSHConfigDiscovery` (literal aliases only, labeled unfollowed Includes)
- Host picker inside the SSH tunnel section; add/edit host; saved password with optional Touch ID before use

## Acceptance criteria

- [x] **AC1.** Literal aliases from `~/.ssh/config` appear; wildcards and `Match` blocks don't; nothing is executed.
- [x] **AC2.** A saved password is stored under `Keel SSH Host` and never shown again.
- [x] **AC3.** With Touch ID required, declining falls back to the ssh prompt relay.

**Verification (KEEL-018).** Observed in `SSHConfigDiscoveryTests`, `HostSecretsTests` (`KeelSSHTests`),
`HostPickerModelTests`, `HostEditorModelTests` (`KeelUITests`) and `ConnectionTesterTests` (`KeelCoreTests`).
- AC1: `testLiteralAliasesOnly` lists only `bastion` from `Host *`, `*.corp`, `!bastion.corp`, `web?`, a
  `Match exec "touch <marker>"` block and an option-like name, and the marker file is never created;
  `testUnfollowedIncludeIsLabeled` labels the Include "not followed". `testCombinesSavedAndDiscoveredHosts` shows
  saved hosts then the not-yet-saved aliases in the picker, with the Include as a note and no pattern or Match entry.
- AC2: `testSavedPasswordIsStoredAndNeverShownAgain` saves through the editor into the host secret store under the
  host's id (the real store's service is asserted as `Keel SSH Host` in `VendoredIdentifiersTests`), wipes the field,
  and a reopened editor shows an empty field with "Saved" while the Keychain is never read. A write to the real login
  Keychain from the running app is **pending** a manual check.
- AC3: `testTouchIDDeclineFallsBack` injects an LAContext stand-in that fails with `userCancel`: the Keychain is not
  read, and the askpass broker sends ssh's password prompt to the prompt relay, whose typed answer goes to ssh. The real
  Touch ID dialog was not exercised (**pending** manual check). `testSavedHostTunnelCarriesItsPasswordLookup` shows Test
  Connection hands a saved host's lookup to the tunnel.

Review fixes: a slow alias import can no longer override a later host choice
(`testLateImportDoesNotOverrideALaterChoice`), and a new host whose password and rollback both failed is edited, not
duplicated, on retry (`testFailedRollbackRetryDoesNotDuplicateTheHost`).

Known limits: the library loads in the background at launch (as `ProfileStore` does); deleting a host and a "saved
host no longer exists" note in the sheet are not in this story; real connects of saved profiles arrive with KEEL-020.

## Unit tests

Test target: `KeelSSHTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `SSHConfigDiscoveryTests.testLiteralAliasesOnly` | ported |
| `SSHConfigDiscoveryTests.testUnfollowedIncludeIsLabeled` | ported |
| `HostPickerModelTests.testCombinesSavedAndDiscoveredHosts` | Combines saved and discovered hosts |
| `HostSecretsTests.testTouchIDDeclineFallsBack` | injected LAContext |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

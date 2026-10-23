# KEEL-055 · Welcome screen and data removal

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 2 pts | S8 | [KEEL-016](KEEL-016-new-connection-sheet-and-test-connection.md), [KEEL-014](KEEL-014-connection-profiles-and-keychain-secrets.md) |

**Specs:** [FR-AP08](../03-functional-requirements.md#7-app-basics), [MAC-22](../07-macos-support.md#installation-upgrades-and-removal)

## Story

As a new or leaving user, I want a friendly start screen and a clean way to remove Keel's data, so that onboarding and uninstalling are easy.

## Scope

- Welcome (no tabs): recent connections, New Connection, Paste URL, Import
- Help → Remove Keel Data…: lists and deletes the state directory and the three Keychain services (`Keel Connection`, `Keel TLS`, `Keel SSH Host`) after confirmation

## Acceptance criteria

- [ ] **AC1.** With no tabs open the welcome screen appears.
- [ ] **AC2.** Remove Keel Data deletes only Keel's files and Keychain items; SSH keys/config are untouched.

## Unit tests

Test target: `KeelUITests, KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `WelcomeModelTests.testRecentConnections` | Recent connections |
| `DataRemovalPlannerTests.testOnlyKeelOwnedItems` | allow-list |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

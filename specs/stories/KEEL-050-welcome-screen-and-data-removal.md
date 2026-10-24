# KEEL-050 · Welcome screen and data removal

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

- [x] **AC1.** With no tabs open the welcome screen appears.
- [x] **AC2.** Remove Keel Data deletes only Keel's files and Keychain items; SSH keys/config are untouched.

## Unit tests

Test target: `KeelUITests, KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `WelcomeModelTests.testRecentConnections` | Recent connections |
| `DataRemovalPlannerTests.testOnlyKeelOwnedItems` | allow-list |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

## Verification (2026-10-24)

- **AC1:** observed in tests. `AccessibilityAuditTests.testEveryControlHasLabel` renders `RootView` for a window
  whose only tab was closed and finds the welcome screen's New Connection…, Paste URL, Import… and the recent row
  ("api-staging, Orange, 127.0.0.1:6379"), every control labeled. `WelcomeModelTests.testRecentConnections` covers
  order, de-duplication, relaunch with "Reopen windows and tabs" off and a deleted profile dropping out;
  `testRecentsAreBounded` the limits (8 saved, 5 shown); the Paste URL tests a filled sheet, a clipboard without a URL,
  and an open Edit sheet left alone.
- **AC2:** observed in tests against a fake home and an in-memory Keychain. `DataRemovalPlannerTests.testOnlyKeelOwnedItems`
  removes every Keel state file and the folder, the three services' items and `keyboardShortcuts`; `~/.ssh` keys,
  `config`, `known_hosts`, another folder's `hosts.json`, look-alike Keychain services and other preference keys stay.
  Also covered: unknown entries keep the folder, home / above home / `~/.ssh` and a symlinked state folder are refused,
  Keychain failures are reported, and the allow-lists match `PersistedFile`, `ProfileSecret` and `KeychainHostSecretStore`.
  `WelcomeModelReviewTests.testNothingIsSavedAfterStopSaving` shows windows aren't written back after the quit flush.
- **Pending:** the end-to-end run of Help → Remove Keel Data… in the built app against the real login Keychain
  (`SystemKeychainInventory` isn't exercised by the tests), and a visual review of the welcome screen in light and
  dark (no welcome board exists in `specs/design/`) and with VoiceOver.
- **Not removed (documented):** imported TLS client identities (they may be shared), the macOS Local Network
  permission and the empty `UserDefaults` domain file.

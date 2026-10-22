# KEEL-016 · New Connection sheet and Test Connection

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 5 pts | S3 | [KEEL-015](KEEL-015-connection-url-parsing-and-paste.md), [KEEL-007](KEEL-007-tls-with-custom-ca-client-identity-and-skip-verify.md), [KEEL-009](KEEL-009-ssh-tunnel-manager.md), [KEEL-011](KEEL-011-server-detection-capability-probes-and-minimum-version.md) |

**Specs:** [FR-CN19, FR-CN10](../03-functional-requirements.md#1-connections), [08 Design → Sheets](../08-design.md#sheets-and-cards)

## Story

As a user, I want a short, calm New Connection sheet with a Test button, so that I can add a server and know it works before saving.

## Scope

- Sheet per design: URL, Name, Host/Port, Username/Password, label dots, Read-only switch, collapsed TLS / SSH tunnel / Advanced rows, Test · Cancel · Save
- Edit Connection uses the same sheet
- Test runs the full handshake without saving and shows one line (✓ Connected or the error category message)

## Acceptance criteria

- [ ] **AC1.** A local profile can be created without opening any collapsed row.
- [ ] **AC2.** Test reports success with server type and latency, or the categorized error, in one line.
- [ ] **AC3.** Cancel discards all changes including pasted passwords; nothing reaches the Keychain.
- [ ] **AC4.** The sheet matches the `Connection` / `ConnectionDark` boards (manual design review).
- [ ] **AC5.** All fields have labels and the sheet is fully keyboard-operable.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ConnectionSheetModelTests.testPasteURLFillsFields` | Paste urlfills fields |
| `ConnectionSheetModelTests.testCancelLeavesNoSecrets` | Cancel leaves no secrets |
| `ConnectionSheetModelTests.testValidationBlocksSave` | empty host, bad port |
| `ConnectionSheetModelTests.testTestConnectionDoesNotPersist` | Test connection does not persist |
| `ConnectionSheetModelTests.testCollapsedSectionsKeepValues` | Collapsed sections keep values |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

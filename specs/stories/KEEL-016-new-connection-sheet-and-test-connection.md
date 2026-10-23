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

- [x] **AC1.** A local profile can be created without opening any collapsed row.
- [x] **AC2.** Test reports success with server type and latency, or the categorized error, in one line.
- [x] **AC3.** Cancel discards all changes including pasted passwords; nothing reaches the Keychain.
- [ ] **AC4.** The sheet matches the `Connection` / `ConnectionDark` boards (manual design review).
- [ ] **AC5.** All fields have labels and the sheet is fully keyboard-operable.

**Verification (KEEL-016).** Observed in `ConnectionSheetModelTests`, `ConnectionSheetModelReviewTests` (`KeelUITests`) and
`ConnectionTesterTests` (`KeelCoreTests`).
- AC1: `testValidationBlocksSave` saves a profile from the defaults plus a password with no row expanded; a blank Name
  takes the host.
- AC2: `ConnectionTesterTests` runs HELLO → PING → INFO server / replication against an in-memory server and reports
  "✓ Connected · Redis 7.4.1 · standalone · N ms"; WRONGPASS, NOPERM, Redis 5.0, a missing CA file and a missing saved
  SSH host each give their FR-CN10 category (the last two open no socket). The sheet shows it in one line, the fix in
  the tooltip and VoiceOver hint; the line hides once a field changes.
- AC3: `testCancelLeavesNoSecrets` pastes a URL with a password, tests, cancels: no Keychain write, no profile, no
  `connections.json`; the password is wiped. `testCancelDuringTestDropsTheResult` covers a test finishing after Cancel.
- AC4 (**pending** manual design review): offscreen renders in light and dark were compared with the boards (layout,
  560 width, tokens, footer); the review in the running app with Inter / JetBrains Mono bundled (KEEL-049) is not done.
  Yellow and purple label dots had no token and were added to 08 Design.
- AC5 (**pending** manual check): every field carries an accessibility label, the label dots read their names with
  the selected trait, collapsed rows read value and expanded state; Return saves, Escape cancels, ⌘T tests, ⌘N opens
  the sheet. VoiceOver and Full Keyboard Access in the running app were not exercised.

Known limits: the client certificate import UI is not in the sheet yet (an edited profile's saved identity is used by
Test); saved SSH hosts appear once KEEL-018 wires the host library; the recovery prompt for `connections.json` is KEEL-055.

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

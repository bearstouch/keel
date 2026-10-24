# KEEL-049 · Settings window

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 3 pts | S8 | [KEEL-044](KEEL-044-design-tokens-themes-and-bundled-fonts.md) |

**Specs:** [FR-AP09](../03-functional-requirements.md#7-app-basics)

## Story

As a user, I want simple settings for theme, browsing, editors, console, keyboard and advanced options, so that I can tune Keel without clutter.

## Scope

- Panes: General, Browser, Editors, Console, Keyboard, Advanced
- Drafts with Apply where live connections are affected; Cancel restores exact prior state

## Acceptance criteria

- [x] **AC1.** Cancelling restores the exact previous settings.
- [x] **AC2.** Separator, page size and auto-page limit apply to new scans.
- [x] **AC3.** Settings persist in `settings.json`.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `SettingsDraftTests.testCancelRestoresPriorState` | Cancel restores prior state |
| `SettingsDraftTests.testApplyPersists` | Apply persists |
| `SettingsTests.testDefaultsMatchSpec` | Defaults match spec |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

## Verification (2026-10-24)

- **AC1:** observed in tests. `SettingsDraftTests.testCancelRestoresPriorState` changes every pane's value and
  previews a theme, then cancels. The draft, the applied settings, the snapshot that scans and connects read, the
  appearance and the `settings.json` bytes all match what they were before. `testClosingTheWindowCancels` checks that
  closing the window cancels too.
- **AC2:** observed in tests. `SettingsTests.testNewScansUseAppliedBrowserSettings` and
  `AppSettingsTests.testRestartTakesTheAppliedBrowserSettings` show that, after Apply, the next scan sends the new
  `COUNT`, uses the new limit and splits the tree at the new separator. Only new scans change: Refresh, a filter
  change, a database switch or a new connection. The running scan keeps its settings, and a profile's own separator
  still wins.
- **AC3:** observed in tests. `testApplyPersists` writes `settings.json` and a fresh model reads it back.
  `testDefaultsMatchSpec` and `testInvalidValuesReadAsDefaults` cover theme-only files and hand-edited bad values.
- Also covered: `AppSettingsTests.testConnectUsesAdvancedAndConsoleSettings` (Advanced timeouts and `CLIENT SETNAME`;
  RESP2 on the console connection only), the default viewer, "Reopen windows and tabs" off, and the accessibility
  audit of every pane.
- **Pending:** a visual review of the panes in light and dark. No Settings canvas exists in `specs/design/`
  (08-design lists the Settings panes as not drawn yet), and the window wasn't checked by eye or with VoiceOver.
- **Deferred by FR-AP09:** the update-check toggle (KEEL-052), TTL display, editor load limits, console font size
  and match chrome.

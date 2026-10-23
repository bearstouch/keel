# KEEL-054 · Settings window

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 3 pts | S8 | [KEEL-049](KEEL-049-design-tokens-themes-and-bundled-fonts.md) |

**Specs:** [FR-AP09](../03-functional-requirements.md#7-app-basics)

## Story

As a user, I want simple settings for theme, browsing, editors, console, keyboard and advanced options, so that I can tune Keel without clutter.

## Scope

- Panes: General, Browser, Editors, Console, Keyboard, Advanced
- Drafts with Apply where live connections are affected; Cancel restores exact prior state

## Acceptance criteria

- [ ] **AC1.** Cancelling restores the exact previous settings.
- [ ] **AC2.** Separator, page size and auto-page limit apply to new scans.
- [ ] **AC3.** Settings persist in `settings.json`.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `SettingsDraftTests.testCancelRestoresPriorState` | Cancel restores prior state |
| `SettingsDraftTests.testApplyPersists` | Apply persists |
| `SettingsTests.testDefaultsMatchSpec` | Defaults match spec |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

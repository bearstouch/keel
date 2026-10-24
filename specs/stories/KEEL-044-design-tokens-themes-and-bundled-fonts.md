# KEEL-044 · Design tokens, themes and bundled fonts

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 5 pts | S3 | [KEEL-001](KEEL-001-package-scaffold-toolchain-and-ci.md) |

**Specs:** [08 Design → Color, Typography](../08-design.md#color), [FR-AP04](../03-functional-requirements.md#7-app-basics), [MAC-19](../07-macos-support.md#input-and-text), [NFR-AX04](../04-non-functional-requirements.md#accessibility)

## Story

As a user, I want Keel's calm light and dark themes with Redis red and the right fonts, so that the app looks like the design everywhere.

## Scope

- `KeelTheme` tokens exactly as 08 Design (light, dark, console, badges, labels); Light default, Dark, System
- Bundle and register Inter and JetBrains Mono for the process; fallbacks
- Increase Contrast and Reduce Motion handling
- Contrast test over all token pairs

## Acceptance criteria

- [x] **AC1.** Token values match 08 Design (test reads a fixture generated from the page). *(ThemeTokensTests.testValuesMatchDesignSpec against `Tests/Fixtures/Design/tokens.json` from `scripts/generate-design-tokens.py`; testFixtureMatchesPage fails on a stale fixture)*
- [x] **AC2.** Inter renders all chrome text; JetBrains Mono renders keys, values and console. *(BundledFontsTests: every face registers for the process and resolves by PostScript name; `Tokens` and `ConsoleTheme` pick Inter / JetBrains Mono faces; SwiftUI roots default to Inter 13, no system text fonts remain)* **Pending:** a visual check in the launched app, light and dark (screen capture wasn't available in this environment).
- [x] **AC3.** All text pairs ≥ 4.5:1, badges and strip ≥ 3:1, in both themes. *(ThemeContrastTests.testAllPairsMeetThresholds over 08 Design → Contrast pairs, light, dark and both Increase Contrast variants; the console hint moved to `#768297` and placeholders to solid `muted` to pass)*
- [x] **AC4.** Switching theme updates live without reconnecting. *(ThemeTests: a switch only sets the app appearance, at once, and is saved in `settings.json`; tokens resolve per appearance)* **Pending:** switching with a connected tab open in the launched app.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ThemeTokensTests.testValuesMatchDesignSpec` | Values match design spec |
| `ThemeContrastTests.testAllPairsMeetThresholds` | All pairs meet thresholds |
| `BundledFontsTests.testFontsRegisterForProcess` | Fonts register for process |
| `ThemeTests.testSystemFollowsAppearance` | System follows appearance |

## Notes

- Theme is chosen in View → Theme (DS-11); KEEL-049 adds it to Settings → General and extends `SettingsDocument` (`SettingsModel` keeps the loaded document's other fields).
- Fonts: Inter 4.1 (rsms/inter release) and JetBrains Mono (from Trellis), with OFL texts; provenance and hashes in `ThirdParty/TrellisShared/PROVENANCE.md`. KEEL-052 must ship the `Keel_KeelUI` resource bundle.
- Increase Contrast is read from the system flag (AppKit can't force high-contrast appearances) and repaints through an appearance round trip. **Pending:** toggling it by hand with each theme, notably for SwiftUI views under an explicit theme.
- Reduce Motion: nothing animates today; any animation must go through `Tokens.animation` (DS-13). TTL countdowns are text and keep ticking.
- Follow-ups: the live design canvas still shows the old console hint `#6B7689` (saved source updated); save-bar and palette shadows use `.black.opacity` rather than a token.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

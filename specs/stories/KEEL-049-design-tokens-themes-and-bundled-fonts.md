# KEEL-049 · Design tokens, themes and bundled fonts

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

- [ ] **AC1.** Token values match 08 Design (test reads a fixture generated from the page).
- [ ] **AC2.** Inter renders all chrome text; JetBrains Mono renders keys, values and console.
- [ ] **AC3.** All text pairs ≥ 4.5:1, badges and strip ≥ 3:1, in both themes.
- [ ] **AC4.** Switching theme updates live without reconnecting.

## Unit tests

Test target: `KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ThemeTokensTests.testValuesMatchDesignSpec` | Values match design spec |
| `ThemeContrastTests.testAllPairsMeetThresholds` | All pairs meet thresholds |
| `BundledFontsTests.testFontsRegisterForProcess` | Fonts register for process |
| `ThemeTests.testSystemFollowsAppearance` | System follows appearance |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

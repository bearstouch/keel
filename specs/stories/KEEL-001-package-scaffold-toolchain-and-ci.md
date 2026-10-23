# KEEL-001 · Package scaffold, toolchain and CI

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E0 Foundation | P0 | 3 pts | S1 | — |

**Specs:** [02 Architecture → Modules](../02-architecture.md#modules), [NFR-QA01](../04-non-functional-requirements.md#quality-and-maintainability)

## Story

As a Keel developer, I want the Swift package, targets, formatter and CI in place, so that every later story builds on a warning-free, linted, tested baseline.

## Scope

- `Package.swift` (swift-tools 6.0, macOS 14, Swift 6 language mode) with targets `KeelRESP`, `KeelSSH`, `KeelAskpass`/`KeelAskpassMain`, `KeelCore`, `KeelUI`, `KeelApp`, `KeelRelease` and matching test targets
- `.swift-format` copied from Trellis (4-space indent, 220 columns)
- `KeelApp` launches an empty window; launch arguments `--state-directory`, `--fixture` parsed
- `.github/workflows/ci.yml` on `macos-26`: format lint, build (fail on warnings), test
- `CLAUDE.md`, `README.md`, `CHANGELOG.md`, `.gitignore`, `release/manifest.json` skeleton

**Out of scope:** any feature code.

## Acceptance criteria

- [x] **AC1.** `swift build` succeeds with zero warnings; `swift format lint --strict -r Sources Tests` prints nothing.
- [x] **AC2.** `swift test` runs at least one test per test target and passes.
- [x] **AC3.** `swift run Keel` opens a native window titled Keel; `swift run Keel --state-directory /tmp/x` uses that folder for state.
- [x] **AC4.** CI runs the same three steps on every push and fails on any warning in `Sources/`.
- [x] **AC5.** `CLAUDE.md` documents commands, the module table and the spec-first workflow, mirroring Trellis.

## Unit tests

Test target: `KeelCoreTests, KeelReleaseTests`.

| Test | Verifies |
| --- | --- |
| `LaunchArgumentsTests.testParsesStateDirectoryAndFlags` | `--state-directory`, `--fixture` parse; unknown flags (including the retired `--no-mcp`) are rejected |
| `LaunchArgumentsTests.testRejectsRelativeStateDirectory` | relative paths are refused |
| `ReleaseManifestTests.testManifestMatchesPackagePlatform` | manifest minimum macOS equals `Package.swift` |
| `AppIdentityTests.testDevBuildsUseDevBundleIdentity` | unbundled runs resolve to `com.bearstouch.keel.dev` |

## Verification notes

- AC1/AC2: clean build with 0 warnings, empty `swift format lint --strict`, 19 tests across all 8 test targets.
- AC3: `Keel --state-directory <dir>` (observed with `--no-mcp`, since removed) ran with an on-screen 1200×792 window owned by the Keel process and created `<dir>` with mode 0700; the title "Keel" is asserted by `MainWindowTests` (the window-list API hides titles without Screen Recording permission, which wasn't requested).
- AC4: CI run 39854236485 on the PR branch passed Lint, Build and Test on `macos-26`; the warning gate was exercised locally with sample logs (a `Sources/` warning fails the step, a `ThirdParty/` warning and a clean log pass).

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

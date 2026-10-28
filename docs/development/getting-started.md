# Getting started

Keel is a Swift package (`Package.swift`). There is no `.xcodeproj`: open the folder in Xcode or use the command
line.

## Requirements

| Tool | Version | Used for |
| --- | --- | --- |
| Xcode | 26 (Swift 6.2); CI and releases pin 26.0.1, see [Known gaps](../project/status.md#known-gaps) | Build, test, `swift format` |
| macOS | 14 or later | Running the app and tests |
| Python 3 | System | Generators, integration matrix, benchmarks |
| Docker (or Colima) | Any recent | Container integration matrix only |
| `redis-server` / `redis-cli` | 7.x | Benchmarks and console goldens (optional) |
| `rsvg-convert`, `actool` | — | App icon assets (optional) |

The package builds in Swift 6 language mode with strict concurrency and must stay warning-free. Sparkle 2 is the only
external package, pinned to an exact version.

## Build, test, run

```sh
swift build                                    # build (must be warning-free)
swift test                                     # full XCTest suite
swift test --filter KeelCoreTests.SafetyPolicyTests   # one test class
swift format -i -r Sources Tests ThirdParty               # format (config: .swift-format)
swift format lint --strict -r Sources Tests ThirdParty    # lint: must print nothing
swift run Keel                                 # run the app (state: com.bearstouch.keel.dev)
swift run Keel --fixture                       # fresh temporary state folder
swift run Keel --state-directory /abs/path     # separate dev state directory
```

`swift format` skips symlinks, so name `ThirdParty` explicitly (the vendored code is symlinked into `Sources`). There
is no SwiftLint or SwiftFormat binary: the toolchain's `swift format` reads the repo's `.swift-format` (copied from
Trellis: 4-space indent, 220 columns, semicolons and multi-variable `let` allowed).

## Launch arguments and state

| Argument | Effect |
| --- | --- |
| *(none)* | Uses the development state folder for `com.bearstouch.keel.dev` |
| `--fixture` | Starts with a fresh temporary state folder |
| `--state-directory /abs/path` | Uses that folder (created owner-only, mode 0700) |

An unknown `--` flag exits with status 64. An unusable state folder (a file, a symlink or another user's folder) exits
with 73. A second launch with a state folder that is already in use brings the running Keel forward and exits with
75 (MAC-17). Development builds use the bundle ID `com.bearstouch.keel.dev`, and installed builds use
`com.bearstouch.keel`. Each has its own state and instance lock, so both can run at once. State layout and formats are
described in [Architecture → Persistence](../architecture.md#persistence).

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/KeelRESP` | RESP2/RESP3 codec, `RedisConnection`, TLS ([API](../api/resp.md)) |
| `Sources/KeelSSH`, `Sources/KeelAskpass*` | OpenSSH tunnels, host library, askpass helper ([API](../api/ssh.md)) |
| `Sources/KeelCore` | Domain layer: profiles, sessions, data path, safety, key index, editors, console ([API](../api/core.md)) |
| `Sources/KeelUI` | SwiftUI and AppKit views, `@MainActor` view models ([API](../api/ui.md)) |
| `Sources/KeelApp` | `@main`, menus, Sparkle wiring ([API](../api/release.md)) |
| `Sources/KeelRelease` | Release manifest, update policy, data removal ([API](../api/release.md)) |
| `ThirdParty/TrellisShared` | Code vendored from Trellis, with `PROVENANCE.md` |
| `Tests/` | XCTest targets per module, `KeelIntegrationTests`, golden fixtures in `Tests/Fixtures` |
| `scripts/` | Generators, integration matrix, benchmarks, packaging |
| `release/` | `Info.plist`, `manifest.json`, icon assets, DMG background, benchmark baseline |
| `docs/` | This documentation |

## Scripts

| Command | Purpose |
| --- | --- |
| `python3 -I scripts/integration-matrix.py [--servers redis-7.4,valkey-9.x] [--filter ServerMatrixTests]` | Container integration matrix (Docker); evidence in `.build/integration/` |
| `python3 -I scripts/generate-command-catalog.py --redis DIR VER --valkey DIR VER --check DIR VER` | Bundled command catalog from the servers' `src/commands` sources |
| `python3 -I scripts/generate-design-tokens.py [--check]` | Design-token fixture (`Tests/Fixtures/Design`) from [Design](../design/index.md) |
| `scripts/generate-app-icon.sh [--check \| --compile DIR]` | App icon assets (`release/icon`) from `keel-icon.svg` |
| `python3 -I scripts/capture-console-goldens.py --redis-server PATH --redis-cli PATH` | Console goldens (`Tests/Fixtures/Console`) |
| `python3 scripts/bench-browser.py [--quick] [--redis-server PATH] [--skip-launch] [--update-baseline]` | 1M/10M-key benchmarks; evidence in `.build/bench/` |
| `scripts/package-release.sh [--no-layout]` | Universal 2 app, DMG, Sparkle archive, appcast and release evidence ([Releasing](releasing.md)) |

## Next steps

- Read the [Product overview](../overview.md) and [Architecture](../architecture.md).
- Learn the [development rules](rules.md) before touching the data path, persistence or SSH.
- Follow the [change workflow](workflow.md) for every change.

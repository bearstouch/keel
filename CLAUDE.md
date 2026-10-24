# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

**Keel** is a native Swift Redis client for macOS by Bearstouch: SCAN-only key browser that stays smooth with
millions of keys, editors for every core type, a redis-cli-style console, an INFO overview, strong production
safety (read-only connections, typed confirmations, bulk delete in batches). It supports Redis 6.0+, Valkey and Dragonfly.
It is a completely independent app: code is vendored from Trellis at build time, nothing is shared at run time.

Status: **early development.** The package scaffold ([KEEL-001](specs/stories/KEEL-001-package-scaffold-toolchain-and-ci.md))
is in place: every target builds, the app opens an empty Keel window, and feature modules hold scaffold markers
(`<Module>Module.swift`) that the first real type in each module replaces. Continue with the next story in sprint order.

- Behavior contract: `specs/` — overview, architecture, functional and non-functional requirements,
  integrations, macOS support and design. The specs win over assumptions; if a page is ambiguous, resolve it in
  the page — never invent conflicting behavior. Requirement IDs (`FR-`, `NFR-`, `INT-`, `MAC-`, `DS-`)
  are stable: never renumber or reuse them.
- Design contract: `specs/08-design.md` plus the saved canvas sources in `specs/design/` (`canvas/` app
  screens, `icon/` the Layered keel app icon). UI work is reviewed against them in light and dark.
- Plan: `specs/stories/README.md` (epics, sprints, definition of done). Work stories in sprint order; one story
  file per change set, its acceptance boxes checked only when observed.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+. The app is a Swift
package (`Package.swift`); there is no `.xcodeproj`. Scripts marked *(later)* arrive with the story named beside them.

```sh
swift build                                    # build (must be warning-free)
swift test                                     # full XCTest suite
swift test --filter KeelCoreTests.SafetyPolicyTests   # one test class
swift format -i -r Sources Tests ThirdParty               # format (config: .swift-format)
swift format lint --strict -r Sources Tests ThirdParty    # lint: must print nothing (swift format skips symlinks, so name ThirdParty)
swift run Keel                                 # run the app (state: com.bearstouch.keel.dev)
swift run Keel --fixture                       # fresh temporary state folder
swift run Keel --state-directory /abs/path     # separate dev state directory
python3 -I scripts/integration-matrix.py [--servers redis-7.4,valkey-9.x] [--filter ServerMatrixTests]   # container matrix (Docker); evidence in .build/integration/
python3 -I scripts/generate-command-catalog.py --redis DIR VER --valkey DIR VER --check DIR VER   # bundled command catalog from src/commands sources
python3 -I scripts/generate-design-tokens.py [--check]   # design-token fixture (Tests/Fixtures/Design) from specs/08-design.md
scripts/generate-app-icon.sh [--check | --compile DIR]   # app icon assets (release/icon) from keel-icon.svg; needs rsvg-convert, --compile only actool
python3 -I scripts/capture-console-goldens.py --redis-server PATH --redis-cli PATH   # console goldens (Tests/Fixtures/Console)
python3 scripts/bench-browser.py [--quick] [--redis-server PATH] [--skip-launch] [--update-baseline]   # 1M/10M-key benchmarks; evidence in .build/bench/, fails on a missed NFR target or a >20% regression vs release/bench-baseline.json
scripts/package-release.sh [--no-layout]       # Universal 2 app, DMG, Sparkle archive, appcast, SHA256SUMS.txt, dist/release-evidence.json; ad-hoc unless KEEL_SIGN_IDENTITY / KEEL_NOTARY_PROFILE; EdDSA via KEEL_SPARKLE_KEY_FILE or KEEL_SPARKLE_ACCOUNT; exits 1 on any failed check
```

There is no SwiftLint/SwiftFormat binary; use the toolchain's `swift format` with the repo `.swift-format`
(copied from Trellis: 4-space indent, 220 columns, semicolons and multi-variable `let` allowed).
Always run format + lint + build + test before committing. CI (`.github/workflows/ci.yml`, `macos-26`) runs the same three steps
and fails on any warning in `Sources/`. Unknown `--` launch flags exit with status 64; an unusable state folder
(a file, a symlink or another user's folder) exits with 73.

## Package layout (`Package.swift`)

| Target | Role |
| --- | --- |
| `KeelRESP` | Engine-independent protocol: streaming RESP2/RESP3 parser and encoder, `RedisConnection` actor over `NWConnection` (TCP, TLS, Unix socket), pipelining, timeouts, bounded replies. No UI, no persistence. |
| `KeelSSH` | SSH tunnels through `/usr/bin/ssh -N` with Unix-socket forwards (`TunnelManager`), saved SSH hosts, `~/.ssh/config` discovery, askpass broker and prompt relay. |
| `KeelAskpass` / `KeelAskpassMain` | `keel-askpass` helper bundled in `Contents/Helpers`. |
| `KeelCore` | Domain: profiles and folders (`ProfileStore` actor), `ServerSession`, server detection, `CommandCatalog`, **`SafetyPolicy`**, **`DataCommandService`** (single data path), `KeyIndex`, value pagers, bulk jobs, persistence, Keychain `SecretStore`, settings. |
| `KeelUI` | SwiftUI chrome and `@MainActor` view models; AppKit `NSOutlineView`/`NSTableView` key lists and `NSTextView` console. |
| `KeelApp` | `@main`, `AppDelegate`, menus built from shortcut bindings, Sparkle wiring, launch arguments. |
| `KeelRelease` | Release manifest checks, update policy, data-removal plan. |
| Tests | `KeelRESPTests`, `KeelSSHTests`, `KeelCoreTests`, `KeelUITests`, `KeelReleaseTests`, `KeelIntegrationTests` (XCTest). |

`ThirdParty/TrellisShared/<Target>` holds code vendored from Trellis (SSH host library, askpass, owner-only storage,
shortcut bindings); the symlink `Sources/<Target>/TrellisShared` compiles it into that target. Record the
Trellis commit and every local change in `ThirdParty/TrellisShared/PROVENANCE.md`; `VendoredIdentifiersTests` fails on any
Trellis Keychain service, state path, `TRELLIS_` variable, helper name or port 7777 in `Sources/`, `ThirdParty/TrellisShared/` or `release/`. Sparkle 2 is the only external package (pinned exact version).

## Architecture rules

- **One data path.** Every command — editors, browser, console, bulk jobs — goes through
  `DataCommandService.execute(_:origin:context:)` and `SafetyPolicy` **before** anything is written to the socket.
  No view or console talks to a `RedisConnection` directly. A blocked command sends nothing.
- Read-only blocks every write, script that may write, admin and unknown command (fail closed). Multi-key delete,
  bulk delete, FLUSHDB and FLUSHALL need a typed confirmation. Admin commands, `KEYS`,
  `MONITOR` and `SUBSCRIBE` run only in the console.
- **SCAN only** for enumeration; the browser never sends `KEYS`. Values load in bounded pages.
- **Bytes, not strings.** Keys and values are byte strings end to end; display escaping never changes the bytes
  used for commands.
- Connections by role (`browser`, `console`, `stream`, `job`); multi-step edits run in `MULTI/EXEC`
  guarded by `WATCH`. A lost reply to a write is `OUTCOME_UNKNOWN`: re-read, never re-send.
- SSH: never implement SSH; build `/usr/bin/ssh` argument arrays without a shell; never add trust-bypass options;
  relay every non-password prompt to the user. Never signal a reused PID.
- Network I/O, parsing, SCAN accumulation and tree building off the main actor; view updates on `@MainActor`.
  Bound every buffer that grows with server data.
- Persistence: versioned Codable JSON, atomic owner-only writes (files 0600, dirs 0700), last-known-good backup,
  single writer, 300 ms debounce. Corrupt/newer state → recovery, never overwrite. Never persist values, key
  names from browsing, console output or history (v1), passwords or tokens.
- Secrets live only in the Keychain (`Keel Connection`, `Keel TLS`, `Keel SSH Host`), written
  before metadata with rollback; connection-affecting edits remove the saved password.
- Values, key names and console text are never logged; `os_log` uses `.private` for any
  server-derived string. No telemetry; the only outbound traffic is configured servers, SSH and the update feed.
- Inject time, filesystem, Keychain, processes and transports so tests are deterministic
  (`RedisConnection` takes a `Transport`; `TunnelManager` takes a process launcher).

## Code style

- Match the surrounding code: compact, dense Swift; short `guard … else { …; return }` bodies and `;`-joined
  trivial statements are normal. Comments are sparse and explain *why*.
- `public` APIs across module boundaries; `Sendable`/`Equatable` value types in Core.
- `@MainActor` for UI-facing classes; actors for stores, sessions, connections, persistence and job runners.
- Error codes are SCREAMING_SNAKE strings shared across modules (`READ_ONLY`, `CONFIRMATION_REQUIRED`, `OUTCOME_UNKNOWN`;
  see `specs/02-architecture.md#errors`).
- UI follows `specs/08-design.md`: only its tokens; Inter for interface text, JetBrains Mono for keys, values and
  the console; Redis red is the accent and never means "warning"; production is the maroon strip with text.
  "Show less, reveal on demand": one toolbar row, one metadata line, secondary actions in `⋯`.
- Accessibility in every view: labels, roles, selected state, focus visible, text never color-only.

## Tests

- XCTest, one class per area, descriptive names; the test names listed in each story are the minimum.
  Review-driven extras go in `*ReviewTests.swift`.
- Assert observable behavior and failure safety (previous state retained on error; blocked commands send nothing).
- Protocol code is tested against in-memory fake servers first; `KeelIntegrationTests` run pinned containers
  (Redis 6.0/6.2/7.4/8.x, Valkey 7.2/8.x/9.x, Dragonfly, TLS and ACL fixtures, sshd). Never test against a user's servers.
- Golden fixtures in `Tests/Fixtures/` (INFO per server, redis-cli outputs, RESP frames).

## Change workflow

1. Pick the next story from `specs/stories/README.md`; read its spec links. For behavior changes or new features,
   update the spec page first or alongside the code, adding new requirement IDs with acceptance checks.
2. Implement with the story's unit tests (observable behavior + failure safety).
3. Format, lint, build, test — all clean.
4. Launch an independent review agent (fresh eyes: correctness, acceptance gaps, security, data loss, races,
   leaks, test gaps). It fixes crucial issues, then formats, lints, builds and tests again.
5. Record what was verified and what remains pending; check acceptance boxes in the story only when observed.
   Update `README.md` / `CHANGELOG.md` if user-visible; refresh `specs/design/` if the design changed.
6. Commit on `master` with Conventional Commits: `feat(<scope>): …` / `fix(<scope>): …` / `docs(<scope>): …`,
   using a module or area as scope.

Honesty rules: acceptance checkboxes stay unchecked unless actually observed. Manual checks that cannot be
performed here (VoiceOver, notarization on a clean Mac, Intel hardware, managed cloud Redis) are recorded as
**pending**, never as passed. Document blockers instead of faking results.

## Gotchas

- Keel is independent of Trellis at run time: never read Trellis's state directory, settings, `hosts.json` or
  Keychain items, and never call the Trellis CLI. Vendored code must use `Keel` names, `KEEL_` env prefix and
  Keel Keychain services.
- Bundle IDs: `com.bearstouch.keel` (installed) and `com.bearstouch.keel.dev` (development builds); separate
  state and instance locks, so both can run at once.
- Minimum server is Redis 6.0; older servers are refused with `UNSUPPORTED_SERVER`. Cluster and KeyDB support are
  later versions — don't add partial support without updating the specs.
- Valkey (7.2 – 9.x) is first-class and release-blocking (INT-01, FR-CN20): never depend on a Redis-only command
  (7.4+/8.x) without a capability probe, and keep the Valkey cases in `KeelIntegrationTests` green.
- macOS 15+ shows the Local Network prompt for LAN servers; keep `NSLocalNetworkUsageDescription` in `Info.plist`
  and surface a denied permission as such, not as a timeout.
- Packaged builds load SwiftPM resources through `Bundle.keelCore` / `Bundle.keelUI` (`Contents/Resources` first); never
  use `Bundle.module` directly, which looks beside `Keel.app` and crashes on a user's Mac.
- `release/Info.plist` is the app's plist; the Sparkle keys there and in `release/manifest.json` are checked by `UpdatePolicyTests`.
- `scripts/package-release.sh` must copy and sign `keel-askpass` and Sparkle's helpers; a new helper goes there,
  in `release/manifest.json` and in the data-removal plan.
- Settings previews are never persisted; cancelling must restore the exact prior state.

# CLAUDE.md

Guidance for Claude Code working in this repository.

## Project

**Keel** is a native Swift Redis client for macOS by Bearstouch: SCAN-only key browser that stays smooth with
millions of keys, editors for every core type, a redis-cli-style console, an INFO overview, strong production
safety (read-only connections, typed confirmations, bulk delete in batches) and an optional MCP server so agents
can control connections and data under the same rules as the UI. It supports Redis 6.0+, Valkey and Dragonfly.
It is a completely independent app: code is vendored from Trellis at build time, nothing is shared at run time.

Status: **specification phase.** No app code exists yet; implementation starts with
[`KEEL-001`](specs/stories/KEEL-001-package-scaffold-toolchain-and-ci.md).

- Behavior contract: `specs/` — overview, architecture, functional and non-functional requirements, agent API,
  integrations, macOS support and design. The specs win over assumptions; if a page is ambiguous, resolve it in
  the page — never invent conflicting behavior. Requirement IDs (`FR-`, `NFR-`, `API-`, `INT-`, `MAC-`, `DS-`)
  are stable: never renumber or reuse them.
- Design contract: `specs/08-design.md` plus the saved canvas sources in `specs/design/` (`canvas/` app
  screens, `icon/` the Layered keel app icon). UI work is reviewed against them in light and dark.
- Plan: `specs/stories/README.md` (epics, sprints, definition of done). Work stories in sprint order; one story
  file per change set, its acceptance boxes checked only when observed.

## Toolchain and commands

Requires Xcode 26 / Swift 6.2 (Swift 6 language mode, strict concurrency), macOS 14+. The app is a Swift
package (`Package.swift`); there is no `.xcodeproj`. Commands below are the target set created by KEEL-001.

```sh
swift build                                    # build (must be warning-free)
swift test                                     # full XCTest suite
swift test --filter KeelCoreTests.SafetyPolicyTests   # one test class
swift format -i -r Sources Tests               # format (config: .swift-format)
swift format lint --strict -r Sources Tests    # lint: must print nothing
swift run Keel                                 # run the app (state: com.bearstouch.keel.dev)
swift run Keel --fixture                       # isolated demo state, never listens for MCP
swift run Keel --state-directory /abs/path     # separate dev state directory
swift run Keel --no-mcp                        # never start the MCP listener
KEEL_INTEGRATION=1 swift test --filter KeelIntegrationTests   # container matrix (Redis/Valkey/Dragonfly/sshd)
python3 scripts/bench-browser.py [--quick]     # 1M/10M-key benchmarks (NFR-PF); evidence in .build/
scripts/package-release.sh                     # Universal 2 DMG; ad-hoc unless KEEL_SIGN_IDENTITY / KEEL_NOTARY_PROFILE
```

There is no SwiftLint/SwiftFormat binary; use the toolchain's `swift format` with the repo `.swift-format`
(copied from Trellis: 4-space indent, 220 columns, semicolons and multi-variable `let` allowed).
Always run format + lint + build + test before committing.

## Package layout (`Package.swift`)

| Target | Role |
| --- | --- |
| `KeelRESP` | Engine-independent protocol: streaming RESP2/RESP3 parser and encoder, `RedisConnection` actor over `NWConnection` (TCP, TLS, Unix socket), pipelining, timeouts, bounded replies. No UI, no persistence. |
| `KeelSSH` | SSH tunnels through `/usr/bin/ssh -N` with Unix-socket forwards (`TunnelManager`), saved SSH hosts, `~/.ssh/config` discovery, askpass broker and prompt relay. |
| `KeelAskpass` / `KeelAskpassMain` | `keel-askpass` helper bundled in `Contents/Helpers`. |
| `KeelCore` | Domain: profiles and folders (`ProfileStore` actor), `ServerSession`, server detection, `CommandCatalog`, **`SafetyPolicy`**, **`DataCommandService`** (single data path), `KeyIndex`, value pagers, bulk jobs, persistence, Keychain `SecretStore`, settings. |
| `KeelControl` | Transport-independent agent API: tool table, grants, capabilities, connection scope, `ApprovalCenter`, idempotency, limits, activity log. |
| `KeelMCP` | Optional MCP server (Streamable HTTP, off by default, loopback, port 7778). |
| `KeelUI` | SwiftUI chrome and `@MainActor` view models; AppKit `NSOutlineView`/`NSTableView` key lists and `NSTextView` console. |
| `KeelApp` | `@main`, `AppDelegate`, menus built from shortcut bindings, Sparkle wiring, launch arguments. |
| `KeelRelease` | Release manifest checks, update policy, data-removal plan. |
| Tests | `KeelRESPTests`, `KeelSSHTests`, `KeelCoreTests`, `KeelControlTests`, `KeelMCPTests`, `KeelUITests`, `KeelReleaseTests`, `KeelIntegrationTests` (XCTest). |

`ThirdParty/TrellisShared` holds code vendored from Trellis (SSH host library, askpass, owner-only storage,
shortcut bindings, MCP HTTP layer). Record the Trellis commit and every local change in
`ThirdParty/TrellisShared/PROVENANCE.md`. Sparkle 2 is the only external package (pinned exact version).

## Architecture rules

- **One data path.** Every command — editors, browser, console, bulk jobs, agents — goes through
  `DataCommandService.execute(_:origin:context:)` and `SafetyPolicy` **before** anything is written to the socket.
  No view, console or MCP tool talks to a `RedisConnection` directly. A blocked command sends nothing.
- Read-only blocks every write, script that may write, admin and unknown command (fail closed). Multi-key delete,
  bulk delete, FLUSHDB and FLUSHALL need a typed confirmation (UI) or an in-app approval (agents). Agents are
  always denied admin commands, `KEYS`, `MONITOR` and `SUBSCRIBE`.
- **SCAN only** for enumeration; the browser never sends `KEYS`. Values load in bounded pages.
- **Bytes, not strings.** Keys and values are byte strings end to end; display escaping never changes the bytes
  used for commands.
- Connections by role (`browser`, `console`, `stream`, `job`, `agent`); multi-step edits run in `MULTI/EXEC`
  guarded by `WATCH`. A lost reply to a write is `OUTCOME_UNKNOWN`: re-read, never re-send.
- SSH: never implement SSH; build `/usr/bin/ssh` argument arrays without a shell; never add trust-bypass options;
  relay every non-password prompt to the user. Never signal a reused PID.
- Network I/O, parsing, SCAN accumulation and tree building off the main actor; view updates on `@MainActor`.
  Bound every buffer that grows with server data.
- Persistence: versioned Codable JSON, atomic owner-only writes (files 0600, dirs 0700), last-known-good backup,
  single writer, 300 ms debounce. Corrupt/newer state → recovery, never overwrite. Never persist values, key
  names from browsing, console output or history (v1), passwords or tokens.
- Secrets live only in the Keychain (`Keel Connection`, `Keel TLS`, `Keel SSH Host`, `Keel Automation`), written
  before metadata with rollback; connection-affecting edits remove the saved password.
- Values, key names, console text and agent payloads are never logged; `os_log` uses `.private` for any
  server-derived string. No telemetry; the only outbound traffic is configured servers, SSH and the update feed.
- Inject time, filesystem, Keychain, processes and transports so tests are deterministic
  (`RedisConnection` takes a `Transport`; `TunnelManager` takes a process launcher).

## Code style

- Match the surrounding code: compact, dense Swift; short `guard … else { …; return }` bodies and `;`-joined
  trivial statements are normal. Comments are sparse and explain *why*.
- `public` APIs across module boundaries; `Sendable`/`Equatable` value types in Core.
- `@MainActor` for UI-facing classes; actors for stores, sessions, connections, persistence and job runners.
- Error codes are SCREAMING_SNAKE strings shared with the API (`READ_ONLY`, `APPROVAL_REQUIRED`, `OUTCOME_UNKNOWN`;
  see `specs/05-api.md#errors`).
- UI follows `specs/08-design.md`: only its tokens; Inter for interface text, JetBrains Mono for keys, values and
  the console; Redis red is the accent and never means "warning"; production is the maroon strip with text.
  "Show less, reveal on demand": one toolbar row, one metadata line, secondary actions in `⋯`.
- Accessibility in every view: labels, roles, selected state, focus visible, text never color-only.

## Tests

- XCTest, one class per area, descriptive names; the test names listed in each story are the minimum.
  Review-driven extras go in `*ReviewTests.swift`.
- Assert observable behavior and failure safety (previous state retained on error; blocked commands send nothing).
- Protocol code is tested against in-memory fake servers first; `KeelIntegrationTests` run pinned containers
  (Redis 6.0/6.2/7.4/8.x, Valkey 8, Dragonfly, TLS and ACL fixtures, sshd). Never test against a user's servers.
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
  state, instance locks and MCP settings, so both can run at once.
- Minimum server is Redis 6.0; older servers are refused with `UNSUPPORTED_SERVER`. Cluster and KeyDB support are
  later versions — don't add partial support without updating the specs.
- macOS 15+ shows the Local Network prompt for LAN servers; keep `NSLocalNetworkUsageDescription` in `Info.plist`
  and surface a denied permission as such, not as a timeout.
- `scripts/package-release.sh` must copy and sign `keel-askpass` and Sparkle's helpers; a new helper goes there,
  in `release/manifest.json` and in the data-removal plan.
- Settings previews are never persisted; cancelling must restore the exact prior state.

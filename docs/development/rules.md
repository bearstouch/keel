# Development rules

These rules hold in every change. Most enforce a requirement; the reason is given so edge cases can be judged. The
full behavior is in [Architecture](../architecture.md) and the [requirements](../requirements/index.md).

## Architecture rules

### One data path

Every command, whether it comes from an editor, the browser, the console or a bulk job, goes through
`DataCommandService.execute(_:origin:context:)` and `SafetyPolicy` **before** anything is written to the socket. No
view or console talks to a `RedisConnection` directly. A blocked command sends nothing.
([Architecture → One data path](../architecture.md#one-data-path))

- Read-only blocks every write, every script that may write, and every admin and unknown command (fail closed).
- Multi-key delete, bulk delete, `FLUSHDB` and `FLUSHALL` need a typed confirmation.
- Admin commands, `KEYS`, `MONITOR` and `SUBSCRIBE` run only in the console.
- Editors produce typed operations, not raw command strings, so the same classification runs for them.

### SCAN only, bounded everything

- Enumeration uses `SCAN`. The browser never sends `KEYS`.
- Values load in bounded pages (`GETRANGE`, `HSCAN`, `LRANGE`, `SSCAN`, `ZRANGE`/`ZSCAN`, `XRANGE`).
- Every buffer that grows with server data has a bound (reply size, scrollback, stream buffers, pushes).

### Bytes, not strings

Keys and values are byte strings end to end. Display escaping never changes the bytes used for commands. Non-UTF-8
data is shown escaped, never silently re-encoded.

### Connections and writes

- Connections are split by role: `browser`, `console`, `stream`, `job`.
- Multi-step edits run in `MULTI`/`EXEC` guarded by `WATCH`.
- A lost reply to a write is `OUTCOME_UNKNOWN`: re-read the key, never re-send the write.

### SSH

- Never implement SSH: use `/usr/bin/ssh`.
- Build argument arrays without a shell. User text only fills an option value or the destination after `--`.
- Never add trust-bypass options (`StrictHostKeyChecking`, `UserKnownHostsFile`, `ProxyCommand`, …).
- Relay every non-password prompt to the user.
- Never signal a reused PID.

### Threading

Network I/O, parsing, SCAN accumulation and tree building run off the main actor. View updates run on `@MainActor`.
([Architecture → Threading](../architecture.md#threading))

### Persistence

- Versioned Codable JSON, atomic owner-only writes (files 0600, folders 0700), last-known-good backup, single
  writer, 300 ms debounce.
- A corrupt or newer-version file goes to recovery and is never overwritten.
- Never persist values, key names from browsing, console output or history (v1), passwords or tokens.
- Settings previews are never persisted, and cancelling restores the exact prior state.

### Secrets

Secrets live only in the Keychain, under the services `Keel Connection`, `Keel TLS` and `Keel SSH Host`. They are
written before metadata, with rollback. Edits that affect the connection remove the saved password.
([Architecture → Keychain items](../architecture.md#keychain-items))

### Privacy and logging

- Values, key names and console text are never logged. `os_log` uses `.private` for any string derived from the
  server.
- No telemetry. The only outbound traffic goes to configured servers, SSH and the update feed.

### Testability

Inject time, the filesystem, the Keychain, processes and transports so tests are deterministic. `RedisConnection`
takes a `Transport`, and `TunnelManager` takes a process launcher.

## Server compatibility

- The minimum server is Redis 6.0. Older servers are refused with `UNSUPPORTED_SERVER`.
- Valkey 7.2–9.x is first-class and release-blocking ([INT-01](../integrations.md#redis-compatible-servers),
  FR-CN20). Never depend on a Redis-only command (7.4+/8.x) without a capability probe, and keep the Valkey cases in
  `KeelIntegrationTests` green.
- Cluster and KeyDB support come in later versions. Don't add partial support without updating the requirements.

## Independence from Trellis

Keel is independent of Trellis at run time. Code is vendored at build time; nothing is shared at run time.

- Never read Trellis's state folder, settings, `hosts.json` or Keychain items, and never call the Trellis CLI.
- Vendored code lives in `ThirdParty/TrellisShared/<Target>` and compiles into that target through the symlink
  `Sources/<Target>/TrellisShared`. It must use Keel names, the `KEEL_` environment prefix and Keel Keychain
  services.
- Record the Trellis commit and every local change in `ThirdParty/TrellisShared/PROVENANCE.md`.
- `VendoredIdentifiersTests` fails on any Trellis Keychain service, state path, `TRELLIS_` variable, helper name or
  port 7777 in `Sources/`, `ThirdParty/TrellisShared/` or `release/`.

## Platform gotchas

- macOS 15+ shows the Local Network prompt for LAN servers. Keep `NSLocalNetworkUsageDescription` in `Info.plist`,
  and report a denied permission as denied, not as a timeout.
- Packaged builds load SwiftPM resources through `Bundle.keelCore` / `Bundle.keelUI` (`Contents/Resources` first).
  Never use `Bundle.module` directly: it looks beside `Keel.app` and crashes on a user's Mac.
- `release/Info.plist` is the app's plist. Its Sparkle keys and those in `release/manifest.json` are checked by
  `UpdatePolicyTests`.
- `scripts/package-release.sh` must copy and sign `keel-askpass` and Sparkle's helpers. A new helper also goes in
  `release/manifest.json` and the data-removal plan.

## Code style

- Match the surrounding code: compact, dense Swift. Short `guard … else { …; return }` bodies and `;`-joined trivial
  statements are normal. Comments are sparse and explain *why*.
- Use `public` APIs across module boundaries, and `Sendable`/`Equatable` value types in Core.
- Use `@MainActor` for UI-facing classes, and actors for stores, sessions, connections, persistence and job runners.
- Error codes are SCREAMING_SNAKE strings shared across modules (`READ_ONLY`, `CONFIRMATION_REQUIRED`,
  `OUTCOME_UNKNOWN`). New codes are added to [Architecture → Errors](../architecture.md#errors).

## UI rules

- Use only the tokens in [Design](../design/index.md). Inter is for interface text; JetBrains Mono is for keys,
  values and the console.
- Redis red is the accent and never means "warning". Production is the maroon strip with text.
- Show less, reveal on demand: one toolbar row, one metadata line, secondary actions in `⋯`.
- Accessibility in every view: labels, roles, selected state, visible focus, and text that never relies on color
  alone.
- UI work is reviewed against the design canvas in light and dark ([Design sources](../design/sources.md)).

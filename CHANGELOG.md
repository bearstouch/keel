# Changelog

All notable changes to Keel are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Swift package scaffold with the Keel targets, an empty Keel window, launch arguments `--state-directory`
  and `--fixture`, owner-only state folder, release manifest, formatter config and CI (KEEL-001).
- Vendored Trellis code in `ThirdParty/TrellisShared` with `PROVENANCE.md`: SSH host library and `~/.ssh/config`
  discovery, the askpass broker and `keel-askpass` helper, owner-only file storage, and rebindable shortcut rules,
  all under Keel names (`Keel SSH Host`, `SSH_ASKPASS_KEEL_*`) (KEEL-002).
- Owner-only versioned persistence for the state files: atomic 0600 writes in a 0700 folder, last-known-good
  backups, sequence-gated 300 ms debounced saves, corrupt files preserved before **Recover backup** / **Start empty**,
  and files from a newer Keel opened read-only (KEEL-003).
- Streaming RESP2/RESP3 codec: every reply type including maps, sets, doubles, booleans, big numbers, verbatim
  strings, pushes and attributes; binary-safe command encoding; replies capped at 64 MiB, 4M elements and 128 nesting
  levels, with malformed frames failing as `PROTOCOL_ERROR` (KEEL-004).
- `RedisConnection`: one pipelined connection per socket over TCP or a Unix socket, with connect and per-command
  timeouts; a timed-out command closes its connection, and a write interrupted by a drop, timeout or close reports
  `OUTCOME_UNKNOWN` and is never re-sent (KEEL-005).
- Connection handshake: `HELLO 3 AUTH … SETNAME keel`, falling back to `AUTH` and `CLIENT SETNAME` on servers without
  `HELLO`, then `SELECT`; `CLIENT SETNAME` can be turned off. Failures map to the FR-CN10 categories (`DNS_FAILED`,
  `CONNECTION_REFUSED`, `TIMEOUT` with its phase, `AUTH_FAILED`, `PERMISSION_DENIED`, `PROTOCOL_ERROR`,
  `DB_OUT_OF_RANGE`) with a message and a suggested fix that name the user, never the password (KEEL-006).
- TLS connections: TLS 1.2 or later, SNI override, anchor-only trust for a custom CA bundle, a client certificate from
  the Keychain and an explicit **Skip verification** that the connection reports as not verified. Failures map to
  `TLS_UNTRUSTED` (naming the issuer), `TLS_HOSTNAME_MISMATCH` (expected and certificate names), `TLS_HANDSHAKE_FAILED`
  (including "Server may not be using TLS" and a required client certificate) and `NOT_TLS_EXPECTED`. Client
  certificates import from `.p12` or a PEM certificate plus an RSA/EC key (PKCS#8, encrypted PKCS#8, PKCS#1, SEC1)
  into the login Keychain; a wrong passphrase imports nothing (KEEL-007).
- CA file change detection: the SHA-256 of each profile's custom CA file is kept in `known-ca.json`; a changed file
  shows the old and new fingerprints and connects only once accepted, and a missing or unusable file fails with
  `TLS_CA_UNAVAILABLE` naming the path (KEEL-008).
- SSH tunnels through `/usr/bin/ssh -N` with a Unix-socket forward in an owner-only runtime folder (no local TCP
  port): one ssh per profile shared by its connections, closed 10 s after the last one; destinations starting with `-`
  are refused and no trust-bypass option is ever added; ssh failing reports `TUNNEL_FAILED` with its exit status and
  sanitized last stderr line, a socket that isn't ready in time `TIMEOUT` (tunnel). Signals go to ssh's own process
  group only while it is still the same process; quitting terminates every tunnel and the next launch cleans up
  tunnels a crashed run left behind (KEEL-009).
- SSH prompts without a terminal: a tunnel's ssh asks through `keel-askpass`, which answers ssh's first password
  prompt from the host's saved password (bound to the host's connection revision) and shows every other prompt —
  unknown or changed host key, key passphrase, one-time code, a second password prompt — in a sheet with ssh's own
  text. Host keys need a click on **Accept**; **Reject** (or 90 s without an answer) fails the connection with "Host
  key not accepted". Only the bundled helper whose parent is that tunnel's ssh is answered (KEEL-010).
- Server detection from `INFO` with data-driven rules (`Resources/ServerDetection.json`: Dragonfly, Valkey, Redis,
  else "Redis-compatible (unrecognized)"), mode from `redis_mode` / `role` with the cluster banner flag, Redis below
  6.0 refused with `UNSUPPORTED_SERVER`, and FR-CN12 capability probes cached per session that pick editor fallbacks
  (`ZRANGEBYSCORE`, `PTTL`, inclusive stream paging) (KEEL-011).
- Command catalog: a bundled catalog of 388 commands and subcommands generated from the Redis 7.4 and Valkey 8
  sources and checked against Valkey 9 (`Resources/Commands`, versioned), with `write`, `readonly`, `admin`,
  `dangerous`, `blocking` and `pubsub` flags, key positions and argument docs rendered as completion syntax. The
  server's `COMMAND` / `COMMAND DOCS` merge over it per session but can never drop a restrictive flag; unknown commands
  and subcommands classify as unknown, never read (KEEL-012).
- One data path: every command from editors, the browser, the console and bulk jobs goes through
  `DataCommandService` and `SafetyPolicy` before anything is sent. Read-only profiles refuse every write, script that
  may write, admin and unknown command with `READ_ONLY` (`EVAL_RO` / `FCALL_RO` still run); multi-key delete, FLUSHDB
  and FLUSHALL need a typed confirmation bound to the exact command and database; admin commands, `KEYS`, `MONITOR`,
  `SUBSCRIBE` and unknown commands run only in the console. `ServerSession` keeps
  `browser`, `console`, `stream` and `job` connections apart and never replays a command (KEEL-013).
- Connection profiles and folders in `connections.json`: create, edit, duplicate, delete and reorder, with revisions
  that refuse stale edits and color labels with editable names (red is the built-in Production label). Passwords and TLS
  secrets live only in the Keychain (`Keel Connection`, `Keel TLS`), written before the metadata and restored if it can't
  be saved; changing the host, port, username, TLS server name or tunnel, turning TLS off or turning Skip verification
  on removes the saved password (KEEL-014).
- Connection URLs: `redis://` and `rediss://` parsing with percent-decoded user and password, `[IPv6]` hosts with
  zone IDs, port and database bounds, ignored query parameters listed by name and inline messages for malformed
  URLs; profiles copy as a URL without the password (KEEL-015).
- New / Edit Connection sheet (File → New Connection…, ⌘N): URL paste fills the form, Name, Host and Port,
  Username and Password, label dots, Read-only, and collapsed TLS, SSH tunnel and Advanced rows. **Test** runs the full
  handshake (tunnel, TLS, AUTH, SELECT, PING, INFO) without saving anything and reports "✓ Connected" with server,
  version, mode and round trip, or the categorized error, in one line. Cancel writes nothing and wipes the password
  (KEEL-016).
- Connections sidebar: top-level profiles and one-level folders in a soft red (light) or graphite (dark) sidebar,
  one-line rows with label dot, name, link icon when connected and "Failed" when failed, host and port in the tooltip;
  drag to reorder or refile profiles and folders, click a heading to collapse it, `+` for a new connection, and a
  context menu with Connect, Edit, Rename, Duplicate, Copy URL (never the password), Move To and Delete. Double-click
  or Return focuses the tab already open for that profile and database (⌥ opens a new one); order, folders and
  collapse state persist across relaunch; VoiceOver reads "payments-prod, Production, connected" (KEEL-017).
- SSH hosts library in the tunnel section: one picker lists Keel's saved hosts (`hosts.json`) and the literal aliases
  of `~/.ssh/config` (no wildcards, no `Match`, nothing run; an unfollowed `Include` is labeled). Choosing an alias saves
  it as a host whose destination is the alias. **Add…** / **Edit…** open a host editor with an optional SSH password
  saved in the Keychain (`Keel SSH Host`), never shown again, and an optional "Require Touch ID" that, when declined,
  sends ssh's password prompt to the person instead. Test Connection uses the saved password for saved hosts (KEEL-018).
- File → **Import Connections…** / **Export Connections…**: profiles and folders as versioned JSON without any secret
  or secret flag; import previews counts and collisions with **Skip existing** (preselected), **Replace existing** or
  **Keep both**, applies in one commit (a failure changes nothing), and refuses files from a newer Keel (KEEL-019).
- SCAN key index for the browser: keys load with `SCAN` only (`COUNT` 1,000) through the single data path, by
  **Load more** (one SCAN per click) or **Auto-page** with pause, up to a loaded-key limit (default 1M, max 10M) with
  **Continue**; repeated keys are listed once, a failed page keeps what was loaded, and the footer reads
  "250,000 of 1.2M keys loaded · Load more" / "All keys loaded". About 36 bytes per key beyond the names (KEEL-020).
- Namespace tree over the loaded keys: a 1–4 byte separator per profile (default `:`), keys that are also folders
  (`a:b` beside `a:b:c`), live key counts per folder as pages load, folders before keys in byte order, and a rebuild
  when the separator changes; binary-safe names shown with redis-cli escaping (`\xff\x00a`) while every action uses
  the original bytes (KEEL-021).
- Virtualized key list: an AppKit `NSOutlineView` tree and `NSTableView` flat view hosted in SwiftUI, 32 px rows with
  name, folder count or TTL and a text type badge, names fetched only for visible rows, View → Toggle Tree / Flat
  (⇧⌘T) keeping the selected key (the tree expands to reveal it), native keyboard navigation, a context menu to copy a
  key name, a redis-cli argument or a folder path, and VoiceOver labels with name, type and TTL (KEEL-022).
- Key filters: a glob pattern sent as `SCAN … MATCH` (applied on Return, with a syntax help popover) and a type menu
  sent as `SCAN … TYPE`; module types ("Other") are checked with a pipelined `TYPE` per key and the bar says so.
  Changing a filter restarts the scan and clears the list at once; Refresh keeps it. The same field also filters the
  loaded keys by substring, live and without the server, showing matches flat; View → Filter Keys (⌘F) focuses it
  (KEEL-023).
- Key rows show their type badge and, for expiring keys only, a short TTL ("1m 30s", "3d") that counts down on this
  Mac and reads "expired" when the key is gone. Types and TTLs are fetched for the rows on screen in pipelined
  `TYPE` + `PTTL` batches, at most one per 100 ms, so an idle list sends nothing. ⋯ → Show Sizes measures the visible
  rows with `MEMORY USAGE … SAMPLES 0`, at most 100 a batch, and only while it is on (KEEL-024).
- Database switcher (`db0 ▾`, View → Database → ⌥⌘0–9) listing db0–db15 or the server's `databases` count, with
  key counts from `INFO keyspace`; cluster servers offer db0 only. Switching keeps the tab and filters and clears
  the list. View → Refresh (⌘R) rescans with the same filters and selects the same key again once it loads; the
  footer shows `DBSIZE` beside the loaded count. Opening a key deleted elsewhere says "Key no longer exists" and
  offers **Remove from List** (KEEL-025).
- Windows and connection tabs: File → New Window (⌘N) and New Tab (⌘T, a connection picker), a tab bar per window
  with label dot, name and ×, tabs that drag between windows (or Move to New Window) and keep their connection, and a
  toolbar with the connection name, the db picker and the Browser | Console | Info switch (⌘1/⌘2/⌘3). Opening a
  connection now connects it and shows its keys; Connection → Reconnect (⇧⌘R) / Disconnect (⇧⌘D). Windows, tabs,
  modes, databases and frames are saved in `windows.json` and restored disconnected, except profiles with Reconnect on
  launch (never production ones). Closing a tab or window with unsaved edits asks first (KEEL-026).
- Editor shell: key name, type badge and `⋯` (Copy name or redis-cli argument, Details with encoding, exact TTL and
  memory on request, "unavailable" when the server won't say), one metadata line ("Expires in 3 days · 6 fields",
  "· Read-only" with a lock), and a floating save bar only while something is unsaved (⌘S / ⌘Z). Saves run as one
  pipelined `MULTI … EXEC` guarded by `WATCH`; a key changed since loading reports `CONFLICT`, writes nothing and
  offers Reload or Overwrite (KEEL-027).
- Value viewer under the editor: Text (UTF-8, other bytes escaped as `\xNN`), JSON (chosen automatically for objects
  and arrays, pretty-printed in key order with syntax colors, "✓ Valid JSON" or the error's line and column), Hex
  (offset, hex, ASCII, drawn lazily) and Raw (redis-cli quoting); Text and Raw edits save byte-exactly, invalid JSON
  can't be saved from JSON view, the chosen view is remembered per key pattern for the session, and values over
  64 KiB are prepared off the main thread. Adds the standard Edit menu (Cut, Copy, Paste, Select All) (KEEL-028).
- String editor: values up to 1 MiB open whole; larger ones show their first 1 MiB as "Partial (1 MiB of 2 MiB)",
  read-only until **Load all** (up to 64 MiB); saving sends `SET … KEEPTTL` inside `WATCH`/`MULTI`/`EXEC`, so the TTL
  is kept, and an unchanged value sends nothing (KEEL-029).

### Removed

- The agent API and the optional MCP server are out of scope for v1: removed from the specs and the plan
  (its five stories deleted and the later stories renumbered KEEL-043–KEEL-052 to close the gap), along with the `KeelControl` and `KeelMCP` targets and the vendored Trellis MCP HTTP
  layer. The `--no-mcp` launch flag is gone and is now refused as an unknown argument.

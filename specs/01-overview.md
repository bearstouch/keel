# 01 Product overview

## Purpose

Keel is a focused native macOS client for Redis 6.0 or later and Valkey 7.2 or later, both first-class targets, plus the Redis-compatible Dragonfly. It makes it easy to connect to many servers, browse and edit their data safely, run commands in a redis-cli-style console, and read server health. It is built to be **safe on production servers by default**, and it lets authorized agents control connections and data through an optional MCP server that applies exactly the same rules as the UI.

Keel follows the Bearstouch quality bar set by Trellis and PostWoman: native SwiftUI and AppKit, keyboard-first, accessible, no telemetry, signed and notarized.

## Users and workflows

- A developer keeps profiles for local, staging and production servers in folders, opens two of them side by side in tabs, and inspects `session:*` keys in a tree.
- An operator connects to production through an SSH bastion, with the profile marked **read-only** and **production**, checks memory and replication on the Info dashboard, and confirms nothing in the UI can write.
- A developer fixes a bad hash field, changes a TTL, and renames a key, each with a clear result and no surprise overwrite.
- An operator removes `tmp:import:*` (2 million keys) with a bulk delete that runs SCAN + UNLINK in batches, watches progress, and can cancel at any time.
- A power user lives in the console: history, command-name completion, redis-cli output.
- An authorized agent (for example Claude Code) lists the connections it was granted, scans keys, reads values, and sets data. Destructive operations wait for the user to approve them in the app.

## Vocabulary

| Term | Definition |
| --- | --- |
| Connection profile | Saved metadata describing how to reach one server: name, color label, host or socket, port, username, database, TLS, SSH tunnel, read-only flag. Its secrets live only in the Keychain. |
| Folder | A named, ordered group of profiles in the sidebar. Folders can nest one level (P0) |
| Server session | The live state for one profile: its socket(s), tunnel, detected server type and version. Opened when a tab connects; closed when the last tab using it closes. |
| Tab | A unit in a window bound to one server session and one selected database. A tab has three modes: **Browser**, **Console** and **Info**. |
| Key | A Redis key. Keys are **byte strings**; Keel identifies keys by their bytes, never by a decoded display string. |
| Namespace | A tree node derived from splitting key names by the separator (default `:`). Namespaces are a view, not server objects. |
| Database | A numbered logical database (`SELECT n`), 0–15 by default. |
| Read-only mode | A per-profile setting that blocks every write, in editors, console, bulk actions and agents. |
| Color label | A per-profile color with a name. The **Production** label additionally decorates window chrome. |
| Destructive operation | DEL/UNLINK of more than one key, bulk delete by pattern, FLUSHDB, FLUSHALL. Each needs a typed confirmation. |
| Grant | A user-created agent credential with capabilities, a connection scope and an expiry. |
| Approval | A one-time, in-app user confirmation an agent needs before a destructive operation runs. |

Structural rules:

- A window has at least one tab or shows the welcome screen; a tab has exactly one server session and one database.
- Several tabs may share one server session; each tab has its own selected database and its own command connection where state differs (see [Architecture](02-architecture.md#connections)).
- Switching tabs never disconnects a server session.
- Profiles never contain secret values. Exports never contain secrets.

## Design principles

1. **Safe by default.** SCAN, never KEYS. Writes honor read-only. Destructive operations need typed confirmation. Large values load in bounded pages.
2. **One data path.** The UI editors, the console, bulk actions and the MCP server all go through one command service and one safety policy. Agents never get a side door.
3. **Bytes, not strings.** Keys and values round-trip byte-exactly. Non-UTF-8 data is shown escaped, never silently re-encoded.
4. **Honest state.** Keel reports what the server returned. It doesn't guess (for example, it shows "TTL unknown" rather than inventing one).
5. **Show less, reveal on demand.** Each screen shows only what the current task needs: one-line rows, no status footers, secondary actions behind a `⋯` menu, Save only when something changed, TLS/SSH/Advanced collapsed until opened, full INFO behind "Show all". Details are one click away, never on screen by default.
6. **Native calm.** SwiftUI chrome, AppKit where performance needs it, Inter for the interface, JetBrains Mono for keys, values and the console, Trellis's visual language.

## Scope

| Priority | Features |
| --- | --- |
| **P0 (v1)** | Connection profiles with folders and color labels; ACL auth; TLS with custom CA, client certificate and skip-verify; SSH tunnel through OpenSSH with Trellis's host library and Keychain passwords; URL paste; test connection; server type and version detection; SCAN-based key browser with tree and flat views, virtualized for millions of keys, pattern and type filters, TTL and type badges, on-demand memory size; database switcher; DBSIZE summary; editors for string, hash, list, set, sorted set and stream (read + add entry); common key actions (rename, TTL, delete, encoding, size); new-key sheet; console with history, completion and redis-cli formatting; read-only mode; production chrome; typed confirmations; bulk delete by pattern with progress and cancel; INFO dashboard; multiple windows and tabs; command palette; rebindable shortcuts; light, dark and system theme; VoiceOver labels; no telemetry and no value logging; Universal 2 signed and notarized DMG; automatic signed updates; optional MCP server with grants and approvals |
| **P1** | Unix-socket connections; Sentinel discovery; Pub/Sub viewer; slow log and CLIENT LIST views; stream consumer groups; export/import of keys (RDB-free JSON dump of a selection); persisted console history (opt-in); local CLI and Unix-socket transport for the API; `keel-mcp` stdio bridge for MCP clients without HTTP |
| **P2** | Redis Cluster (slot-aware browsing across masters); KeyDB detection and qualification; RedisJSON, RedisTimeSeries, Bloom and search module editors; value formatters (MessagePack, Protobuf with user schema, gzip); memory analysis over a full scan; key diff between two servers; plugins |

Out of scope for v1: Windows, Linux or iOS; cloud sync; a web UI; an embedded AI model; an embedded SSH implementation; KEYS-based browsing; RDB file parsing; server administration that changes configuration from forms (CONFIG SET stays available only through the console).

## Primary interaction

```text
┌──────────────┬──────────────────────────────────────────────────────────────┐
│ ● ● ●        │ local-dev  db0 ▾        [Browser | Console | Info]        ⌕  │ ← toolbar
│              ├──────────────────────────────────────────────────────────────┤
│ Connections +│ ● local-dev × │ ● api-staging × │ ● payments-prod × │ +      │ ← tabs
│ Production   ├──────────────────────────────────────────────────────────────┤
│ ● payments   │ [ Production · Read-only ]   (only on production tabs)       │
│ ● orders     ├────────────────────────┬─────────────────────────────────────┤
│ Staging      │ ⌕ user:*               │ user:1042  HASH                  ⋯  │
│ ● api-stg    │ ▼ user        48,210   │ Expires in 3 days · 6 fields        │
│ Local        │     1042   3d   HASH   │ Field        Value                  │
│ ● local-dev  │ ▶ session    902,114   │ email        ana.silva@example.com  │
│              │ ▶ cache      180,002   │ preferences  {"theme":"dark",…}     │
│              │                        │ ┌ preferences  [Text|JSON|Hex|Raw] ┐│
│              │                        │ │ { "theme": "dark", … }           ││
│ ◆ Keel       │ 250,000 of 1.2M · Load │ └──────────────────────────────────┘│
└──────────────┴────────────────────────┴─────────────────────────────────────┘
```

- The left sidebar lists saved connections in folders. Double-click or Return connects in a new tab (or focuses the existing tab for that profile and database, with ⌥ to force a new one).
- **Browser** mode: key list on the left, value editor on the right (key header, one metadata line, field table, value viewer), resizable split.
- **Console** mode: a dark, monospaced redis-cli-style console scoped to the tab's connection and database. Also available as a bottom panel in Browser mode.
- **Info** mode: the INFO dashboard.
- Light chrome is the first-launch default; Dark and System are available. Redis red is the accent; Inter is the interface font; keys, values and the console use JetBrains Mono. The full visual contract is [08 Design](08-design.md).

## Definition of done for v1

A user can save profiles for a local server, a TLS server with a custom CA, and a server behind an SSH bastion; connect to all three; browse a million-key database smoothly; edit every supported type; run console commands; mark a profile read-only and production and see that nothing can write; bulk-delete a pattern with progress and cancel; and read the INFO dashboard.

An agent with a grant can list its connections, scan, read and write data, and is blocked or asked for approval exactly where the UI would block or confirm. Every result and error it receives is documented in [05 API](05-api.md).

### Cross-feature acceptance scenario

1. Paste `rediss://app:…@cache.internal:6380/2` into New Connection. The fields fill in, the password moves to the Keychain, and the URL isn't saved.
2. Test the connection with a wrong password: the error says authentication failed (`WRONGPASS`), not "connection failed".
3. Save a second profile through an SSH host imported from `~/.ssh/config`; connect; the tunnel uses OpenSSH and an unknown host key is shown to the user for confirmation.
4. In a database of 1,000,000 keys, load keys with auto-paging, switch between tree and flat views, filter `user:*` and type `hash`. Scrolling stays smooth.
5. Edit a hash field, change a TTL, rename a key (rename refuses to overwrite an existing key without a confirmation).
6. Mark the profile read-only: the editors become view-only, `SET` in the console is blocked with a clear message, and an agent's `value_set` returns `READ_ONLY`.
7. Bulk-delete `tmp:*` on a non-read-only profile: the typed confirmation requires `tmp:*`; cancel half-way; the summary reports how many keys were removed.
8. Enable the MCP server, create a grant scoped to one profile, connect Claude Code, and confirm the agent can't see the other profiles (`NOT_FOUND`) and that its `db_flush` waits for an in-app approval.
9. Quit and reopen: profiles, folders, windows and tabs are restored, disconnected until the user connects (or reconnect automatically if that per-profile option is on).

## Milestones

1. **Protocol feasibility:** RESP2/RESP3 client over Network.framework, TLS (custom CA, client identity, skip-verify), OpenSSH tunnel with the askpass relay, detection on Redis, Valkey and Dragonfly fixtures.
2. **Browse:** profiles, folders, Keychain, SCAN key index, virtualized tree and flat views, filters, db switcher.
3. **Edit:** the six type editors, common key actions, new-key sheet, safety policy, read-only, confirmations, bulk delete.
4. **Console and Info:** console, completion, formatting, INFO dashboard.
5. **Agents:** command catalog, grants, approvals, MCP server, activity log.
6. **Release qualification:** performance targets, accessibility pass, multiple windows, signing, notarization, Sparkle updates, the acceptance matrix on both architectures and on the minimum and current macOS.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Product name | **Keel** | Bundle ID `com.bearstouch.keel` |
| Independence | Keel is a completely independent app: it never reads or writes Trellis's data, settings, hosts or Keychain items, and has no runtime integration with Trellis | Code and visual design may be vendored from Trellis at build time; nothing is shared at run time |
| Minimum server | Redis 6.0 (and compatible servers implementing the 6.0 command set) | ACL users, `HELLO`/RESP3, `SCAN TYPE`, `UNLINK`, `KEEPTTL` are always available, so v1 needs no pre-6.0 fallbacks |
| Cluster | Later version (P2) | v1 detects cluster mode and shows a banner that browsing covers the connected node only |
| KeyDB | Later version (P2) | KeyDB reports `redis_version` 6.x, so v1 treats it as Redis without KeyDB-specific detection or qualification |
| Agent-created profiles | Allowed with `connection.write` | Agents never set, read or learn about secrets; a profile that needs a password gets it from the user in the UI |
| Redis client | In-house RESP2/RESP3 client on Network.framework (`KeelRESP`) | No SwiftNIO dependency, native TLS with Security.framework (custom CA, client identities from the Keychain), full control over byte-exactness, pipelining and bounds |
| SSH | System OpenSSH (`/usr/bin/ssh -N`) with a Unix-socket local forward | Same rule as Trellis: never implement SSH; the user's config, agent, keys and known hosts apply |
| Trellis reuse | Vendored copy of Trellis's SSH host library, askpass helper, owner-only storage and MCP HTTP layer in `ThirdParty/TrellisShared`, with recorded provenance | Source reuse only, no runtime link to Trellis; avoids a cross-repo release dependency |
| Sandbox | Not sandboxed (Developer ID, hardened runtime) | Needs `/usr/bin/ssh`, `~/.ssh/config`, and arbitrary certificate paths |
| Updates | Sparkle 2, EdDSA-signed appcast | The one network call besides user-initiated connections; opt-out |
| Visual design | Redis-red accent, Inter + JetBrains Mono, light sidebar in soft red, dark theme on Trellis native graphite; "show less, reveal on demand" | Recognizably a Redis tool, calm and uncluttered; see [08 Design](08-design.md) and the saved canvas in `specs/design/` |
| Large lists | AppKit `NSOutlineView` / `NSTableView` hosted in SwiftUI | SwiftUI `List` can't stay smooth with millions of rows |

## Open questions

None at the moment. Resolved questions are recorded in [Decisions](#decisions).

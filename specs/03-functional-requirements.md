# 03 Functional requirements

Every requirement has a stable ID, a priority and an acceptance check. Unless marked otherwise, requirements here are **P0**. All server commands go through the [single data path](02-architecture.md#one-data-path); "blocked" always means nothing was sent to the server.

## 1. Connections

### Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-CN01 | Create, edit, duplicate, delete and reorder connection profiles with: name, color label, host, port (default 6379), username (optional, ACL), password, default database index (0–15 or the server's `databases` count), read-only flag, connect/command timeouts. | A saved profile reconnects with the same settings after relaunch. Deleting a profile removes its metadata, its Keychain items and any open tabs for it after a confirmation listing them. |
| FR-CN02 | Color labels: None, Red, Orange, Yellow, Green, Blue, Purple, Gray, each with an editable name. The built-in **Production** label (red) is special (FR-SF02). | The label shows as a dot plus the label name in the sidebar, the tab and the profile editor. VoiceOver reads the label name. |
| FR-CN03 | TLS: on/off, server name (SNI) override, custom CA (PEM file), client certificate (Keychain identity, importable from `.p12` or PEM certificate + key), and **Skip verification**. | Connecting to a server signed by a private CA succeeds only with that CA selected. A client-cert-required server rejects a profile without an identity with a TLS error. With Skip verification on, the tab and window show "TLS not verified" in text. |
| FR-CN04 | Changing the contents of a referenced CA file is detected by fingerprint and asks before trusting the new file. | Replace the CA file: the next connect shows the old and new SHA-256 fingerprints and connects only after the user accepts. |
| FR-CN05 | SSH tunnel through one of Keel's saved SSH hosts (host library vendored from Trellis) or an inline destination; Redis host and port are resolved **from the SSH server's side**. | A profile with host `127.0.0.1` via bastion `ops` reaches the bastion's local Redis. Each tunnel is a `/usr/bin/ssh -N` process with a Unix-socket forward ([Architecture](02-architecture.md#ssh-tunnels)). |
| FR-CN06 | SSH host discovery from `~/.ssh/config` (literal aliases only; no wildcards, no `Match`, never runs `Match exec`) and saved SSH passwords in the Keychain, exactly as Trellis FR-H03, FR-H06–FR-H09. | Discovered aliases appear in the tunnel host picker; an `Include` that isn't followed is labeled. A saved password is used once per connection for ssh's password prompt only. |
| FR-CN07 | SSH prompts other than the saved password (unknown or changed host key, key passphrase, OTP) are shown in a sheet with ssh's exact text. Keel never answers them itself. | Connecting to a new bastion shows the host-key fingerprint prompt; declining fails the connection with "Host key not accepted". |
| FR-CN08 | Paste a connection URL to fill a profile: `redis://[user[:password]@]host[:port][/db]` and `rediss://…` (TLS). Percent-encoding is decoded; IPv6 hosts in brackets are accepted. | Pasting into the URL field or anywhere in the New Connection sheet (⌘V on the sheet) fills the fields. The password goes to the Keychain on save; the URL itself is never saved. Unknown query parameters are listed as "ignored" instead of silently dropped. |
| FR-CN09 | Passwords and key passphrases are stored only in the Keychain. | `connections.json`, exports, diagnostics, the API and logs contain no secret values; at most a `hasPassword` flag (never exposed to agents). |
| FR-CN10 | **Test Connection** runs the full handshake (tunnel, TLS, AUTH, SELECT, `PING`, `INFO server`) without saving and reports a categorized result. | Each category below produces its own message and suggested fix; success shows server type, version, mode and round-trip time. Nothing is saved: no profile, no Keychain item and no CA fingerprint record (the CA file is read and checked only); a tunnel opened for the test is released afterwards. |
| FR-CN11 | Detect server type (Redis, Valkey, Dragonfly, unknown Redis-compatible), version and mode (standalone, replica, cluster, sentinel) from `INFO server` / `INFO replication`. | Fixtures for each server type are identified correctly ([INT-02](06-integrations.md#detection)). Unknown servers show "Redis-compatible (unrecognized)" and still work. A server reporting a Redis version below 6.0 fails with `UNSUPPORTED_SERVER` ("Keel requires Redis 6.0 or later; this server is Redis 5.0.7") and no tab opens. A cluster node shows a banner: "Cluster mode: browsing this node only". |
| FR-CN12 | Probe the features that vary within the supported range (6.0+ and compatible servers) instead of assuming them: `MEMORY USAGE`, `OBJECT ENCODING`, `COMMAND DOCS` (7.0), `ZRANGE … BYSCORE` and `XRANGE` exclusive ranges (6.2), `PEXPIRETIME` (7.0), `EVAL_RO` (7.0). | On Redis 6.0, zsets page with `ZRANGEBYSCORE` and the expiry time is computed from `PTTL`; on Dragonfly a missing `OBJECT ENCODING` shows "unavailable". |
| FR-CN13 | Sidebar of saved connections grouped into folders (one level of nesting), with drag-and-drop reordering, rename, collapse state and search (⌘K). Each row is **one line**: label dot and name; a connected profile adds a link icon; a failed one adds the word "Failed". Hosts, ports and counts aren't shown in the row (they're in the tooltip and the editor). A "+" beside the Connections heading creates a profile; the Keel mark sits at the bottom left ([08 Design](08-design.md#sidebar)). | Moving a profile between folders survives relaunch. Search matches name, host and label name. VoiceOver reads "payments-prod, Production, connected". |
| FR-CN14 | Export and import profiles and folders as versioned JSON **without secrets**; import previews counts and conflicts and never overwrites without an explicit collision policy. | An exported file contains no password, passphrase, token, or `hasPassword`. Re-importing with "Skip existing" changes nothing. |
| FR-CN15 | Disconnect and Reconnect are explicit actions per tab and per profile. Optional per-profile **Reconnect on launch** (off by default; always off for Production-labeled profiles unless explicitly set). | After relaunch tabs show "Disconnected · Connect" unless the option is on. |
| FR-CN19 | New Connection sheet shows, in order: a URL field ("Paste a URL to fill the form"), Name, Host and Port, Username and Password ("saved in Keychain"), color label dots, a **Read-only** switch, then collapsed rows **TLS**, **SSH tunnel** and **Advanced** that open their settings in place, and the footer Test · Cancel · Save. | A plain local profile can be created without opening any collapsed row. Test reports one short line ("✓ Connected" or the error category). |
| FR-CN20 | **Valkey parity** ([INT-01](06-integrations.md#redis-compatible-servers)): Valkey 7.2 – 9.x is a first-class, release-blocking target. Features that need commands Valkey lacks degrade through capability probes (FR-CN12), never by failing. | The browser, every editor, the console, the INFO overview and the agent tools pass the same integration suite on Valkey 7.2, 8.x and 9.x as on Redis 7.4; a failing Valkey case fails CI ([NFR-QA03](04-non-functional-requirements.md#quality-and-maintainability)). |
| FR-CN16 (P1) | Unix-socket connections (`unix:///path/redis.sock`, `redis+unix://`). | |
| FR-CN17 (P1) | Sentinel master discovery. | |
| FR-CN18 (P2) | Redis Cluster browsing across all masters. | |

### Connection error categories (FR-CN10)

| Category | Typical cause | Message names |
| --- | --- | --- |
| `DNS_FAILED` | Host can't be resolved | The host |
| `CONNECTION_REFUSED` | Nothing listening | Host and port |
| `TIMEOUT` | Connect or handshake exceeded the timeout | Which phase (TCP — "TCP and TLS" for a TLS profile, AUTH, tunnel) and the timeout |
| `TLS_UNTRUSTED` | Chain doesn't verify against system or custom CA | Issuer, and that a custom CA can be selected |
| `TLS_HOSTNAME_MISMATCH` | Certificate doesn't match the server name | Expected name and certificate names; suggests SNI override |
| `TLS_HANDSHAKE_FAILED` | Protocol mismatch, client cert required or refused, or server not speaking TLS | "Server may not be using TLS" when a plain `PING` to the same port gets a RESP reply ([Architecture](02-architecture.md#tls)); "requires a client certificate" when the profile has none, "rejected the client certificate" when it has one; the `errSSL` status |
| `NOT_TLS_EXPECTED` | TLS server reached without TLS: it answered with a TLS record | Suggests enabling TLS |
| `TLS_CA_UNAVAILABLE` | The custom CA file is missing, unreadable, not a regular file, over 4 MiB or holds no readable certificate (FR-CN04); nothing is sent | The file's path and the reason |
| `TLS_CA_CHANGED` | The custom CA file's SHA-256 changed and the user declined the new fingerprint (FR-CN04); nothing is sent | The file's path |
| `AUTH_FAILED` | `WRONGPASS`, `NOAUTH`, `ERR invalid password`, user disabled | Username (never the password); for `NOAUTH`, that a password is required |
| `PERMISSION_DENIED` | `NOPERM` during handshake (e.g. `SELECT`, `INFO`) | The command the ACL user can't run |
| `TUNNEL_FAILED` | ssh exited, forward failed, host key declined, or the tunnel settings were invalid (nothing runs) | ssh exit status and sanitized last stderr line; the SSH destination; a fix chosen from ssh's message (host key, permission denied, forwarding, DNS) |
| `PROTOCOL_ERROR` | The port doesn't speak RESP | "This port doesn't look like a Redis server" |
| `DB_OUT_OF_RANGE` | `SELECT` fails | The index and the server's database count (from `CONFIG GET databases`, when permitted) |
| `CONNECTION_FAILED` | The connection dropped during the handshake, or another OS error | Host and port, the handshake step; suggests TLS when the server may require it |
| `SERVER_ERROR` | Any other error reply during the handshake | The step and the server's error code (scrubbed text in details) |

## 2. Key browser

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-KB01 | Key enumeration uses **only** `SCAN` (with `MATCH`, `COUNT`, and `TYPE` when supported). `KEYS` is never sent by the browser. | A protocol trace of browsing, filtering and refreshing contains no `KEYS`. |
| FR-KB02 | Keys load in pages (default `COUNT` 1,000). The user picks **Load more** (manual) or **Auto-page** (keeps scanning while the list is visible, up to the loaded-key limit, default 1,000,000). The list footer is one quiet line: "250,000 of 1.2M keys loaded · Load more" ("All keys loaded" when the cursor returns to 0); scanning can be paused from the ⋯ menu. Keys SCAN returns more than once are listed once. At the limit the footer reads "… · Limit reached · Continue": Continue raises the limit by the configured amount again (never past 10,000,000, where Continue is no longer offered); the part of the last page that didn't fit is held back and added first, so no key is skipped. A failed page keeps the loaded keys and cursor ("… · Scan failed: … · Retry" resends the same cursor). Without a known total the footer shows the loaded count only ("250,000 keys loaded"). | Manual mode loads exactly one SCAN iteration per click. Auto-page stops at the limit with a notice and a "Continue" action. |
| FR-KB03 | Tree view groups keys by a separator (default `:`, configurable per profile, any 1–4 byte string). Nodes show child key counts for loaded keys. A key can also be a namespace (`a:b` and `a:b:c`). Flat view lists full key names. Toggle with ⌘⇧T. | `a:b` shows both as a leaf and a folder. Counts update as pages load. Switching views keeps the selection. |
| FR-KB04 | The list is virtualized and stays smooth with millions of loaded keys ([NFR-PF02](04-non-functional-requirements.md)). | 1,000,000 loaded keys scroll at display frame rate; expanding a node with 500,000 children is under 200 ms. |
| FR-KB05 | Filter by pattern (server-side `MATCH`, glob syntax with a help popover) and by type (string, hash, list, set, zset, stream, other). Changing a filter restarts the scan. A quick local filter (substring over loaded keys) is also available. | `user:*` + `hash` lists only hashes under `user:`. The type filter uses `SCAN … TYPE`; for module and unknown types ("other") it is applied client-side and says so. |
| FR-KB06 | Each row shows a type badge (text, not color only) and TTL only when the key expires (short form such as "3d" or "12m"; nothing for keys without expiry, so rows stay quiet; "expired" if gone; the full value is in the editor and the VoiceOver label). TTLs count down while visible and refresh on demand. | A key with `EXPIRE 90` shows "1m 30s" and counts down; after expiry the row shows "expired" and is removed on the next refresh. |
| FR-KB07 | Memory size is shown **only when requested**: per key (context menu, editor header) or for the visible rows ("Show sizes"), using `MEMORY USAGE key SAMPLES 0` only on user request, in bounded batches. | Browsing without "Show sizes" sends no `MEMORY USAGE`. With it on, only visible rows are measured, at most 100 per batch. |
| FR-KB08 | Database switcher for db0–db15 (or the server's `databases` count when `CONFIG GET databases` is permitted), showing key counts from `INFO keyspace`. Switching keeps the tab and clears the list. ⌥⌘0…⌥⌘9 select db0–db9. | Databases with keys show their count; cluster-mode servers offer db0 only. |
| FR-KB09 | Refresh (⌘R) restarts the scan keeping filters and, when possible, the selection. The header shows `DBSIZE` for the selected db, with the loaded count beside it. | After adding a key elsewhere, ⌘R shows it and DBSIZE increments. |
| FR-KB10 | Binary-safe keys: keys that aren't valid UTF-8 display with redis-cli escaping (`\xNN`); every action uses the original bytes. Copy offers "Copy name" (display) and "Copy as redis-cli argument" (quoted). | A key `\xff\x00a` can be opened, edited, renamed and deleted. |
| FR-KB11 | Context menu and keyboard actions on keys: open, open in new tab, copy name, rename, set TTL, delete, show size. Multi-selection supports delete (FR-SF04) and copy names. | Selecting 3 keys and pressing ⌫ shows a typed confirmation listing them. |
| FR-KB12 | Keys removed or changed elsewhere are handled honestly: opening a missing key shows "Key no longer exists" and offers to remove it from the list. | Delete a key in another client, select it in Keel: the message appears and nothing crashes. |

## 3. Value editors

Common rules for all editors:

- Values are bytes. The viewer has a small **Text / JSON / Hex / Raw** switch at its top right (JSON is chosen automatically when the value parses, with a "✓ Valid JSON" note). For hashes, lists, sets, zsets and streams, selecting a row opens that element in the viewer under the table. Viewers: **Text** (UTF-8, invalid bytes shown escaped), **JSON** (pretty-printed, validated, with error line/column), **Hex** (offset, hex, ASCII), **Raw** (redis-cli escaped). The selected viewer is remembered per key pattern for the session.
- Large values load in bounded pages; partial content is marked "Showing 1–500 of 82,113" and editing operates only on loaded items.
- Edits are explicit: change → **Save** (⌘S) / **Revert** (⌘Z before save). A floating bar ("1 unsaved change · Revert · Save") appears at the bottom of the editor **only** while there are unsaved changes; changed rows get a small accent dot. Unsaved changes are confirmed on close.
- Save **preserves TTL** (`SET … KEEPTTL` for strings; collection edits don't touch TTL).
- Concurrency: whole-value saves use `WATCH key` + `MULTI/EXEC`; if the key changed since it was loaded, the save fails with `CONFLICT` and offers Reload or Overwrite.
- Read-only profiles show editors in view mode: "· Read-only" with a lock in the metadata line, no Add/Save controls, and write actions disabled in the ⋯ menu. Viewing (including the viewer switch) is unchanged.

| ID | Type | Requirement | Acceptance check |
| --- | --- | --- | --- |
| FR-ED01 | String | View and edit with Text, JSON, Hex and Raw viewers; save with SET preserving TTL. Values up to 1 MiB load fully; larger ones load the first 1 MiB with `GETRANGE` and offer "Load all" up to 64 MiB; editing is disabled for partial loads. | A 2 MiB string shows "Partial (1 MiB of 2 MiB)" with editing disabled until fully loaded. Invalid JSON can be saved only from Text view (JSON view blocks it with the parse error). |
| FR-ED02 | Hash | Field/value table with sorting by field and local filter; add, edit value, rename field (HSET new + HDEL old in one MULTI), delete fields. Uses `HSCAN` (COUNT 500) with Load more for hashes over 1,000 fields; small hashes use `HGETALL`. Field values open in the string viewer set. | Renaming a field to an existing field name asks before overwriting. A 1M-field hash opens in under 1 s showing the first page. |
| FR-ED03 | List | Indexed table paged with `LRANGE` (500 per page), jump to index, edit by index (`LSET`), push and pop at head or tail (`LPUSH`/`RPUSH`/`LPOP`/`RPOP`), insert before/after (`LINSERT`), delete by index (LSET to a random sentinel + `LREM 1` in one MULTI). | Deleting index 3 of a 10-item list leaves 9 items in the original order. Index changes made elsewhere since the page loaded are detected (`WATCH`) and reported as `CONFLICT`. |
| FR-ED04 | Set | Member list via `SSCAN` (or `SMEMBERS` when `SCARD` ≤ 1,000), add (`SADD`), remove (`SREM`), local filter, member count from `SCARD`. | Adding an existing member reports "already a member" (SADD returned 0). |
| FR-ED05 | Sorted set | Member/score table **sorted by score** (ascending/descending toggle), paged with `ZRANGE … BYSCORE … LIMIT` (6.2+) or `ZRANGEBYSCORE`, pattern search with `ZSCAN`; add (`ZADD`), change score (`ZADD XX`), increment (`ZINCRBY`), remove (`ZREM`). Scores show full double precision and `inf`/`-inf`. | A 100k-member zset shows the lowest scores first and pages forward; changing a score moves the row to its new position after save. |
| FR-ED06 | Stream | Read-only entry table (ID, then field/value pairs) paged with `XRANGE`/`XREVRANGE` (500 per page, newest first by default), entry count from `XLEN`, stream info summary (`XINFO STREAM`: length, first/last ID, groups count). **Add entry** sheet (auto `*` ID or explicit, field/value rows) via `XADD`. | Adding an entry with `*` shows the server-assigned ID at the top. Entries can't be edited in v1; `XDEL` and consumer groups are P1. |
| FR-ED07 | Other types | Module types (`ReJSON-RL`, `TSDB-TYPE`, `MBbloom--`, …) and unknown types show type name, TTL, encoding and size with a "No editor for this type" notice; common actions (rename, TTL, delete) still work. | A RedisJSON key opens with the notice and can be deleted. |

### Common key actions

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-ED10 | Rename a key with `RENAMENX` by default. If the target exists, ask whether to overwrite, then use `RENAME`. Keys can't be renamed to an empty name. | Renaming onto an existing key without confirming changes nothing. |
| FR-ED11 | Set, change or remove TTL: presets (1 min, 1 h, 1 day, 7 days), custom duration or absolute date/time (`PEXPIRE` / `PEXPIREAT`), and **Persist** (`PERSIST`). Shows the absolute expiry time (`PEXPIRETIME` on 7.0+, else computed). | Setting TTL to 1 h shows the expiry clock time; Persist shows "—". |
| FR-ED12 | Delete the open key (`UNLINK`) with a normal confirmation (single key). | The key disappears from the list and the editor shows the empty state. |
| FR-ED13 | The editor header shows the key name, the type badge and **one** line of metadata: expiry and length ("Expires in 3 days · 6 fields", plus "· Read-only" when applicable). Encoding (`OBJECT ENCODING`), exact TTL and memory size (`MEMORY USAGE`, on request) are in ⋯ → Details. Rename, Set TTL, Copy and Delete are in the ⋯ menu (and their shortcuts). Missing permission or support shows "unavailable", never an error dialog. | On Dragonfly or an ACL user without `OBJECT`, encoding shows "unavailable". |
| FR-ED14 | New-key sheet (⇧⌘N in Browser): key name (prefilled with the selected namespace + separator), type picker (string, hash, list, set, zset, stream), first value(s) appropriate to the type, optional TTL. Creation fails if the key exists (`SET NX`, or `EXISTS` check inside `WATCH`/`MULTI` for other types). | Creating `user:9` when it exists shows "Key already exists" and creates nothing. The new key is selected after creation. |
| FR-ED15 | Copy value, and export the open value to a file (raw bytes, or JSON for collections) via the save panel. | Exporting a binary string writes identical bytes. |

## 4. Console

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-CO01 | An embedded redis-cli-style console per tab, scoped to that tab's profile and database, on its own connection. The prompt shows `name[db]>` like redis-cli (`127.0.0.1:6379[2]>`). `SELECT n` in the console changes only the console's database and the prompt. | Running `SELECT 3` in the console doesn't change the browser's db. |
| FR-CO02 | Input parsing follows redis-cli rules: whitespace-separated arguments, double quotes with `\n \r \t \b \a \\ \" \xNN` escapes, single quotes literal. Unbalanced quotes show an inline error, nothing is sent. | `SET k "a\x00b"` stores 3 bytes. |
| FR-CO03 | Output formatted the way redis-cli formats RESP2 replies: `(integer) 5`, `"value"` with escaping, `(nil)`, `(error) ERR …`, `(empty array)`, nested numbered arrays with indentation. RESP3 types use redis-cli 7 notation (`(double)`, `(true)`, maps as `1# "k" => "v"`, sets with `~`). The console uses RESP2 by default; RESP3 is a console option (`HELLO 3`). | Golden-output tests compare formatting with redis-cli 7.4 for a fixed command set. |
| FR-CO04 | Command history per profile, in memory (↑/↓, ⌃R reverse search), deduplicated, 1,000 entries. History is never persisted in v1 (P1 opt-in, with credential commands redacted). | History survives switching tabs, not relaunch. |
| FR-CO05 | Autocomplete for command names (Tab / ⌃Space) from the server's `COMMAND DOCS` when available, otherwise the bundled catalog, including subcommands (`CLIENT LIST`, `XINFO STREAM`). Inline hint shows the argument syntax (like redis-cli hints). Key-name completion from the loaded index is P1. | Typing `HSC` + Tab completes `HSCAN` and shows `key cursor [MATCH pattern] [COUNT count] [NOVALUES]`. |
| FR-CO06 | Every console command goes through the safety policy: read-only blocks writes with `(error) KEEL_READ_ONLY write commands are blocked on this connection`; dangerous and multi-key-delete commands show a confirmation; `KEYS` warns with DBSIZE. | `FLUSHDB` asks for the typed confirmation (FR-SF03); `KEYS *` on a 1M-key db shows the warning first. |
| FR-CO07 | Streaming commands (`MONITOR`, `SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`) run on a dedicated connection with a visible **Stop** (⌘.) and bounded output (keeps the newest 10,000 lines). Blocking commands (`BLPOP` etc.) show a waiting indicator and can be cancelled (closes that connection). | Stop ends MONITOR within 1 s; the console prompt returns. |
| FR-CO08 | Visual style follows Trellis's terminal: a dark pane (`#151719`) in both themes, JetBrains Mono 14, prompt in muted gray, errors in soft red, a Redis-red cursor, ⌘+/⌘− zoom. The console has no extra header or footer; the completion list shows command names only, with the argument hint inline after the cursor. ⌘K is the command palette, so **Clear console** is ⌥⌘K (and ⌃L inside the console). | Matches the Console boards in the design canvas. |
| FR-CO09 | Copy output, copy a single reply, clear the console. Output is bounded (scrollback 10,000 lines / 16 MiB). Console output is never written to disk or logs. | |
| FR-CO10 | `AUTH`, `HELLO … AUTH`, `ACL SETUSER … >password`, `CONFIG SET requirepass`/`masterauth` and `MIGRATE … AUTH` arguments are masked in the console echo and excluded from history. | After `AUTH secret`, history and the echoed line show `AUTH ••••••`. |

## 5. Safety

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SF01 | **Read-only mode** per profile blocks every write (catalog `write` flag, scripts that may write, unknown commands, admin commands) in editors, the console, bulk actions, the new-key sheet and agents. Toggling it off on a Production-labeled profile asks for confirmation. | With read-only on, a protocol trace of every editor action and console write shows nothing sent; agents get `READ_ONLY`. `EVAL_RO`/`FCALL_RO` still work. |
| FR-SF02 | Production chrome: a 28 px strip under the tab bar, deep maroon (light `#7A1A14`, dark `#4A1F1C`), with centered text "Production · Read-only" ("Production" alone when writes are allowed). The tab keeps its label dot, and the Window menu title includes "[PROD]". Text is always present, so color isn't the only signal, and the maroon is deliberately different from the Redis-red accent. Any label can be marked "treat as production". | A Production tab in the frontmost window shows the strip; switching to a non-production tab removes it. |
| FR-SF03 | Typed confirmations for destructive operations: deleting more than one key (type the number of keys), bulk delete by pattern (type the pattern), **FLUSHDB** (type the database, e.g. `db3`), **FLUSHALL** (type the profile name). The confirm button stays disabled until the text matches exactly; Return doesn't confirm. On Production profiles the sheet also names the server. | Typing `tmp:` for pattern `tmp:*` leaves Delete disabled. |
| FR-SF04 | Multi-key delete from a selection uses `UNLINK` in batches of 500, after FR-SF03 confirmation. | Deleting 2,000 selected keys sends 4 UNLINK commands. |
| FR-SF05 | **Bulk delete by pattern**: `SCAN MATCH <pattern> COUNT 1000` + `UNLINK` in batches on the `job` connection. The confirmation is one sentence ("About 2.1 million keys match `tmp:import:*` in api-staging. This can't be undone.") with an optional **Preview matches** link (first 100) and the typed confirmation. While running it shows a progress bar, one line ("1,221,000 deleted · about a minute left") and **Cancel**; scanned/matched/rate are in the final report. Pattern `*` is refused; use FLUSHDB. | Cancel stops within one batch; the report states the deleted count and that keys created during the run may remain (SCAN guarantees). The browser stays responsive during the job. |
| FR-SF06 | Optional throttle for bulk jobs (default 10 batches/s, configurable 1–100, or unthrottled) to protect production latency. | With throttle 2, a job issues at most 2 UNLINK batches per second. |
| FR-SF07 | Write commands on Production profiles that aren't read-only show a non-blocking "Writing to PRODUCTION" banner in the editor and console the first time per tab. | |
| FR-SF08 | `KEYS` and other O(N) commands on large databases (`KEYS`, `SMEMBERS`/`HGETALL`/`LRANGE 0 -1` on > 10,000 elements, `FLUSHALL` without `ASYNC`) warn in the console with the size before sending. Editors never issue them unbounded. | |

## 6. Server info

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-SI01 | **Info** mode shows an overview: four tiles (Memory used of maxmemory with a bar, Clients, Operations per second, Uptime), a **Databases** list (keys per db with Browse) and a **Health** list (replication, last save, hit ratio). **Show all INFO fields** opens every section (Server, Memory, Clients, Keyspace, Persistence, Replication, Stats, CPU) and a searchable Raw view. | Every field from `INFO` appears under Show all; unknown fields from other servers aren't dropped. |
| FR-SI02 | Tile values match `INFO` at the same refresh; server type and version appear beside the connection name in the toolbar. | |
| FR-SI03 | Auto-refresh off by default; interval 2 s, 5 s, 10 s, 30 s from the refresh button's menu; manual ⌘R. Sparklines are P1. | With refresh on, `INFO` is sent at the interval only while Info mode is visible. |
| FR-SI04 | Keyspace section lists databases with keys, expires and avg TTL, each with "Open in Browser". | |
| FR-SI05 | Missing permissions (`NOPERM` on INFO) or servers lacking sections show "unavailable" per section. | |
| FR-SI06 (P1) | Slow log, `CLIENT LIST`, latency doctor views. | |

## 7. App basics

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-AP01 | Multiple native windows (⌘N / File → New Window). Each window has a **tab bar** under the toolbar with one tab per open connection: label dot, name, close ×, and a + for a new tab; the active tab is raised and joins the content. Drag a tab to another window or out to a new one. macOS automatic window tabbing is disabled. | Two windows can show different tabs of the same profile; windows, tabs, modes and selected db restore after relaunch (disconnected, FR-CN15). |
| FR-AP02 | Keyboard-first: every primary action is in the menus and reachable from the keyboard. Default shortcuts below; all configurable shortcuts are rebindable in Settings → Keyboard with conflict detection (Trellis `KeyboardShortcuts` rules). | Rebinding ⌘R to an existing shortcut is rejected with the conflicting action named. |
| FR-AP03 | **Command palette** (⌘K): fuzzy search over actions, connections, open tabs, databases, recent keys (in memory) and settings. | ⌘K, type "prod pay", Return opens the payments-prod connection. |
| FR-AP04 | Theme: Light (default), Dark, System, using the Keel palettes in [08 Design](08-design.md#color): Redis-red accent in both; light sidebar in a soft red tint; dark theme on Trellis's native graphite grays. The console stays dark in both. Honors Increase Contrast and Reduce Motion. | Token values match 08 Design. |
| FR-AP05 | Accessibility labels, roles and states on every control; VoiceOver can read rows ("user:1042, hash, expires in 3 days"), editor cells, status, and the production strip. | See [NFR-AX](04-non-functional-requirements.md#accessibility). |
| FR-AP06 | No telemetry; values, key names and console output are never logged. | See [NFR-PV](04-non-functional-requirements.md#privacy). |
| FR-AP07 | Automatic updates with Sparkle 2: check daily (default on, can be turned off), signed EdDSA appcast over HTTPS, user confirms install, "Check for Updates…" in the app menu. No system profile is sent. | See [MAC-08](07-macos-support.md). |
| FR-AP08 | Welcome screen with no tabs: recent connections, New Connection, Paste URL, Import. | |
| FR-AP09 | Settings: General (theme, updates, restore behavior), Browser (default separator, page size, auto-page limit, TTL display), Editors (default viewer, load limits), Console (font size, RESP version, match chrome), Keyboard, Agents (MCP switch with interface and port under its Details, Access list, activity; FR-RC), Advanced (timeouts, CLIENT SETNAME default). Changes are drafts until Apply where they affect live connections; cancel restores the exact prior state. | |
| FR-AP10 | Diagnostics export (Help → Export Diagnostics): app version, macOS, architecture, profile **count** and server types, recent error codes; never hosts, key names, values, or secrets. | |

### Default shortcuts

| Action | Default |
| --- | --- |
| New window / new tab (connection picker) | ⌘N / ⌘T |
| New key (Browser mode) | ⇧⌘N |
| Close tab / close window | ⌘W / ⇧⌘W |
| Command palette | ⌘K |
| Filter keys | ⌘F |
| Refresh | ⌘R |
| Browser / Console / Info mode | ⌘1 / ⌘2 / ⌘3 |
| Toggle console panel (Browser) | ⌘J |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Select db0–db9 | ⌥⌘0 – ⌥⌘9 |
| Toggle tree / flat | ⇧⌘T |
| Save value / revert | ⌘S / ⌘Z |
| Delete selected key(s) | ⌘⌫ |
| Rename key / set TTL | ⌘E / ⌥⌘E |
| Stop streaming command | ⌘. |
| Clear console | ⌥⌘K (⌃L also works as a console editing key) |
| Zoom data font | ⌘+ / ⌘− / ⌘0 |
| Disconnect / reconnect | ⇧⌘D / ⇧⌘R |
| Hide / show sidebar | ⌃⌘S |

Settings (⌘,), Hide, Quit, Undo/Redo, Cut, Copy, Paste, Select All and Minimize can't be rebound.

## 8. Remote control (MCP server)

The API and its security are specified in [05 API](05-api.md). These requirements cover the settings UI.

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| FR-RC01 | Settings → Agents → **Allow agents to connect (MCP)** turns the MCP server on and off. **Off by default.** The choice is saved; `--no-mcp` and `--fixture` launches never listen. | A fresh install has no listener. Enable + Apply starts it, and it survives relaunch. |
| FR-RC02 | Interface (IPv4/IPv6 literal, never a hostname) and port (1024–65535, default 7778 to avoid Trellis's 7777). | Invalid values can't be applied; the running server is unchanged. |
| FR-RC03 | Non-loopback interfaces need explicit confirmation warning that traffic is plain HTTP. | Cancel keeps the previous settings. |
| FR-RC04 | Status in text: running at URL, stopped, or failed with reason ("Port 7778 is already in use"). | |
| FR-RC05 | Settings → Agents: one switch **Allow agents to connect (MCP)** with its address underneath; an **Access** list (one row per grant: name, a plain-language summary like "Read and write · local-dev, api-staging", status) with **Add agent…**; grant details (capabilities, connection scope, expiry 1 h / 1 d / 7 d / 30 d / 90 d, revoke) in each row's ⋯ menu; **Copy setup command for Claude Code**. The token is shown once at creation. | Revoking disconnects the agent at once. |
| FR-RC06 | **Approval card**: a pending agent approval appears as a non-modal card and a notification: "Allow this agent request?" with one sentence naming the agent, the operation, the estimated impact and the connection; the same typed confirmation as the UI; **Deny** / **Allow once**. Approvals expire after 5 minutes. | An agent `db_flush` shows a pending approval; typing `db0` and allowing lets the agent's retry succeed once. |
| FR-RC07 | **Agent activity** (Settings → Agents → ⋯ → Activity): in-memory list of recent agent calls (time, grant, tool, connection, db, key names truncated to 64 bytes, result code). Never values. Cleared at quit. A grant row shows "Connected" while an agent session is open. | |
| FR-RC08 | A global **Pause agents** switch rejects all agent calls with `AGENTS_PAUSED` without revoking grants. | |

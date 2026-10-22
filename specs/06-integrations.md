# 06 Integrations

Keel relies on the system and on existing tools rather than reimplementing them. This page sets the boundaries with servers, macOS services, Trellis and agent clients.

## Redis-compatible servers

**INT-01 (P0): supported servers.**

| Server | Versions | Level | Notes |
| --- | --- | --- | --- |
| Redis | 6.0 – 8.x | Full | Minimum supported version is 6.0; older servers are refused with `UNSUPPORTED_SERVER` |
| Valkey | 7.2 – 8.x | Full | Treated as Redis 7.2-compatible plus Valkey-specific INFO fields |
| Dragonfly | 1.x | Full for the common command set | Some `OBJECT`/`MEMORY`/`DEBUG` subcommands differ; capability probes decide |
| Managed services (AWS ElastiCache/MemoryDB, Azure Cache, GCP Memorystore, Upstash, Redis Cloud) | — | Best effort | Commonly rename or disable `CONFIG`, `INFO` sections or `COMMAND`; Keel degrades to "unavailable" per feature |

The CI integration matrix is in [NFR-QA03](04-non-functional-requirements.md#quality-and-maintainability). Never test against a user's production servers during development.

### Detection

**INT-02 (P0).** Detection uses `INFO server` (and `HELLO` replies when available), applied in this order; the first match wins. The rules are data in `Resources/ServerDetection.json`, each with a fixture test:

| Order | Signal | Result |
| --- | --- | --- |
| 1 | `dragonfly_version` field | Dragonfly, that version |
| 2 | `server_name:valkey` or `valkey_version` field | Valkey, `valkey_version` (else `redis_version`) |
| 3 | `redis_version` field | Redis, that version |
| — | none | "Redis-compatible (unrecognized)" |

KeyDB isn't detected separately in v1: it reports `redis_version` 6.x and is treated as Redis. KeyDB detection and qualification are planned for a later version (P2). Cluster browsing is also a later version (P2).

Mode: `redis_mode` (`standalone`, `cluster`, `sentinel`) and `role` from `INFO replication`. Features are enabled by **capability probing** (FR-CN12), never by version alone; version only selects the bundled command catalog when `COMMAND` is unavailable.

## Protocol

**INT-03 (P0).**

- RESP2 and RESP3. Browser and agent connections use RESP3 when `HELLO 3` succeeds (typed maps, doubles, booleans), else RESP2. The console uses RESP2 by default for redis-cli-identical output.
- Authentication: `HELLO 3 AUTH <user> <pass>`, or `AUTH <user> <pass>`, or `AUTH <pass>` (`requirepass` / the `default` user), chosen by profile fields and server support.
- Pipelining for TYPE/PTTL batches; `MULTI/EXEC` with `WATCH` for multi-step edits; no client-side caching (`CLIENT TRACKING`) in v1.
- Command metadata from `COMMAND INFO` / `COMMAND DOCS`; bundled fallback catalog generated from Redis 7.4 and Valkey 8 sources, versioned, with a test that every command used by the editors is classified.
- Pub/Sub and MONITOR only on dedicated console connections (FR-CO07).
- Sentinel is P1 and Cluster (`MOVED`/`ASK`) is P2; in v1 a `MOVED` reply is shown as an error with the target node.

## Connection URLs

**INT-04 (P0).** Parsing follows the IANA `redis` and `rediss` URI schemes as used by redis-cli and common clients:

| Part | Mapping |
| --- | --- |
| `redis://` / `rediss://` | TLS off / on |
| `user:password@` | Username and password (percent-decoded); `:password@` alone means password only |
| `host` | Hostname, IPv4, or `[IPv6]` |
| `:port` | Default 6379 |
| `/db` | Database index (0 if absent) |
| Query (`?…`) | Not applied in v1; listed to the user as ignored |

Keel can also **copy** a profile as a URL without the password (`redis://user@host:port/db`).

## TLS and certificates

**INT-05 (P0).** TLS uses Network.framework with Security.framework trust evaluation; no OpenSSL.

- System trust store by default; custom CA bundle (PEM) as anchor-only trust per profile.
- Client identities live in the login Keychain. Keel imports `.p12` files, or a PEM certificate plus PEM/PKCS#8 private key (encrypted keys prompt for a passphrase saved under `Keel TLS`), into the Keychain, and stores only the persistent reference.
- Keel never writes to the system keychain or changes trust settings for other apps.

## SSH tunnels

**INT-06 (P0).** Same boundaries as Trellis INT-03–INT-05:

- `/usr/bin/ssh` runs as the user with their configuration, agent, keys, known hosts, `ProxyJump` and `ProxyCommand`. Keel doesn't implement SSH and never edits SSH configuration.
- Tunnels are `ssh -N` with a Unix-socket local forward in an owner-only runtime directory ([Architecture](02-architecture.md#ssh-tunnels)).
- Saved SSH passwords: Keychain (`Keel SSH Host`), given to ssh only for its password prompt, once per tunnel, through `keel-askpass` with nonce and peer checks.
- Every other ssh prompt is relayed verbatim to the user; Keel never answers host-key prompts and never adds trust-bypass options.
- Discovery reads literal `Host` aliases from `~/.ssh/config` (no wildcards, no `Match`, never executes anything).

## Trellis

**INT-07 (P0).** Keel is a **completely independent app**.

- At run time Keel never reads or writes Trellis's state directory, settings, saved hosts or Keychain items, and doesn't call the Trellis CLI or API. Keel's SSH hosts come only from Keel's own host library and `~/.ssh/config`.
- **Source reuse only:** SSH hosts, discovery, askpass, owner-only storage, shortcut bindings and the MCP HTTP layer are vendored from Trellis into `ThirdParty/TrellisShared` with `PROVENANCE.md`, and renamed to Keel identifiers.
- **Visual reuse:** Trellis's terminal colors for the console and its native graphite grays for the dark theme. Keel's accent (Redis red), light sidebar tint and fonts (Inter, JetBrains Mono) are its own ([08 Design](08-design.md)).
- Both apps can run at once without conflicts: separate bundle IDs, state directories, Keychain services and MCP ports (Keel 7778, Trellis 7777).

## Keychain and LocalAuthentication

**INT-08 (P0).** Generic passwords for services `Keel Connection`, `Keel TLS`, `Keel SSH Host`, `Keel Automation`, *when unlocked, this device only*. Optional per-profile "Require Touch ID to connect" uses LocalAuthentication before the password is read (enforced by Keel, as in Trellis FR-H07). Ad-hoc development builds may prompt for Keychain access again after a rebuild.

## Agents and MCP clients

**INT-09 (P0).**

- Any MCP client supporting Streamable HTTP and custom headers can connect ([05 API](05-api.md)); Claude Code is the reference client and is tested in the release checklist.
- Keel embeds no AI model and obtains no provider API keys.
- Server data is untrusted and labeled so for agents.
- **P1:** `keel-mcp` stdio bridge (bundled helper) for clients that only support stdio; it forwards to the local Unix-socket transport and reads its token from the Keychain, never argv.

## Clipboard

**INT-10 (P0).** `NSPasteboard` only on explicit copy/paste. The clipboard is never polled. Pasting a connection URL is recognized only in the New Connection sheet (FR-CN08). Agents have no clipboard access.

## Updates

**INT-11 (P0).** Sparkle 2 (pinned exact version), EdDSA-signed appcast and updates, HTTPS feed on the Bearstouch release host, `SUEnableSystemProfiling = NO`, automatic checks on by default with a user-visible toggle, user-confirmed installs. Release builds verify both the Developer ID signature and the EdDSA signature. See [MAC-08](07-macos-support.md).

## Import and export

**INT-12 (P0).**

- Profiles and folders: versioned JSON, no secrets (FR-CN14).
- Values: single-key export to a file (FR-ED15). Multi-key export/import is P1.
- Importers for other clients (RedisInsight, Another Redis Desktop Manager, Medis) are P2; each must map only the fields it supports and list what it leaves out, and never import passwords into files.

## Dependencies

| Dependency | Use | Policy |
| --- | --- | --- |
| Sparkle 2 | Updates | SwiftPM, exact version, checksum verified; MIT |
| `ThirdParty/TrellisShared` | Vendored Bearstouch code | Provenance and local patches recorded |
| JetBrains Mono | Console and data font | OFL 1.1, bundled, registered for the process only |
| Inter | Interface font | OFL 1.1, bundled, registered for the process only |
| Redis / Valkey / Dragonfly containers | Integration tests only | Pinned image digests in CI |
| OpenSSH | Tunnels | The system's own |

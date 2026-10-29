# Integrations

Keel relies on the system and on existing tools rather than reimplementing them. This page sets the boundaries with servers, macOS services and Trellis.

## Redis-compatible servers

**INT-01 (P0): supported servers.**

| Server | Versions | Level | Notes |
| --- | --- | --- | --- |
| Redis | 6.0 – 8.x | Full | Minimum supported version is 6.0; older servers are refused with `UNSUPPORTED_SERVER` |
| Valkey | 7.2 – 9.x | Full, first-class (release-blocking) | Treated as Redis 7.2-compatible plus Valkey-specific INFO fields; parity rules below |
| Dragonfly | 1.x | Full for the common command set | Some `OBJECT`/`MEMORY`/`DEBUG` subcommands differ; capability probes decide |
| Managed services (AWS ElastiCache/MemoryDB, Azure Cache, GCP Memorystore, Upstash, Redis Cloud) | — | Best effort | Commonly rename or disable `CONFIG`, `INFO` sections or `COMMAND`; Keel degrades to "unavailable" per feature |

**Valkey parity.** Valkey is a first-class target, not best effort. Every P0 and P1 feature works on Valkey with the same behavior as on Redis 7.2+, or degrades through capability probes (FR-CN12) exactly as it would on a Redis server lacking that feature. Commands added only in Redis 7.4+ or 8.x (for example hash-field TTL or Redis 8 data types) are never assumed; they are probed and shown as "unavailable" when missing. A Valkey failure in the integration matrix blocks a release exactly like a Redis failure ([FR-CN20](requirements/functional.md)).

The CI integration matrix is in [NFR-QA03](requirements/non-functional.md#quality-and-maintainability). Never test against a user's production servers during development.

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

A family with a minimum version (Redis 6.0) that reports an older or unparseable version is refused with
`UNSUPPORTED_SERVER`. Versions compare numerically on their leading numbers (`df-v1.24.0` is 1.24.0).

**Probes.** Each FR-CN12 probe is one read-only command on a key named `keel:probe:<uuid>` that almost surely doesn't
exist: `MEMORY USAGE`, `OBJECT ENCODING`, `COMMAND DOCS GET`, `ZRANGE <key> 0 0 BYSCORE`, `XRANGE <key> (0-0 + COUNT 1`,
`PEXPIRETIME`, `EVAL_RO "return 0" 0`. Any non-error reply (or "no such key") means available. A cluster redirect
(`MOVED`/`ASK`: the probe key hashes to another node) or an ACL denial for the key only comes after the server accepted
the command, so it means available for `MEMORY USAGE`, `OBJECT ENCODING` and `PEXPIRETIME`, and unavailable for the
argument forms (`BYSCORE`, exclusive `XRANGE`), whose fallbacks work everywhere. Any other error reply (unknown command
or subcommand, syntax, a command `NOPERM`, a disabled command) means unavailable and the feature takes its fallback
(`ZRANGEBYSCORE`, `PTTL`, an inclusive start one past the last stream ID) or shows "unavailable" (`UNSUPPORTED`).
Results are cached for the session; a connection failure or a transient error (`LOADING`, `BUSY`, `TRYAGAIN`,
`MASTERDOWN`, `CLUSTERDOWN`) is not cached and is probed again on the next use.

## Protocol

**INT-03 (P0).**

- RESP2 and RESP3. Browser connections use RESP3 when `HELLO 3` succeeds (typed maps, doubles, booleans), else RESP2. The console uses RESP2 by default for redis-cli-identical output.
- Authentication: `HELLO 3 AUTH <user> <pass>`, or `AUTH <user> <pass>`, or `AUTH <pass>` (`requirepass` / the `default` user), chosen by profile fields and server support.
- Pipelining for TYPE/PTTL batches; `MULTI/EXEC` with `WATCH` for multi-step edits; no client-side caching (`CLIENT TRACKING`) in v1.
- Command metadata from `COMMAND INFO` / `COMMAND DOCS`; bundled fallback catalog generated from Redis 7.4 and Valkey 8 sources and checked against Valkey 9, versioned, with a test that every command used by the editors is classified.
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

Keel can also **copy** a profile as a URL without the password (`redis://user@host:port/db`). The copy always names the port
and database, percent-encodes the user name and brackets IPv6 hosts (`%25` before a zone ID), and parses back to the
same connection fields.

Parsing details: the scheme is case-insensitive and surrounding whitespace from a paste is trimmed. Userinfo ends at
the **last** `@`, so an unencoded `@` in a password still parses; empty user or password parts are absent. Passwords
are decoded to bytes (any byte is allowed); user names must decode to UTF-8 without spaces or control characters.
IPv6 hosts must be valid addresses (an optional zone is a non-empty interface name or number) and are stored without brackets; other hosts never contain `[`, `]` or `%`. Database `/` or no path is 0; the port is 1–65535 and the database 0–65535.
Raw spaces, control characters, a `#fragment`, an unbracketed IPv6 address, invalid `%` escapes or URLs over 4 KiB
are malformed: the sheet shows an inline message and changes no field. Applying a URL sets host, port, user, database
and TLS (a `rediss://` paste keeps an existing TLS server name and CA); every other field is kept, and a blank name
takes the host.

## TLS and certificates

**INT-05 (P0).** TLS uses Network.framework with Security.framework trust evaluation; no OpenSSL.

- System trust store by default; custom CA bundle (PEM) as anchor-only trust per profile.
- Client identities live in the login Keychain. Keel imports `.p12` files, or a PEM certificate plus PEM/PKCS#8 private key (encrypted keys prompt for a passphrase saved under `Keel TLS`), into the Keychain, and stores only the persistent reference. Supported keys: RSA and EC, as PKCS#8 (plain or PBES2-encrypted), PKCS#1 or SEC1; legacy `Proc-Type: 4,ENCRYPTED` PEM keys are refused with "convert with `openssl pkcs8 -topk8`". A wrong passphrase or a key that doesn't match the certificate imports nothing ([Architecture](architecture.md#tls)). The import is reached from the connection sheet's TLS row (FR-CN03).
- Keel never writes to the system keychain or changes trust settings for other apps.

## SSH tunnels

**INT-06 (P0).** Same boundaries as Trellis INT-03–INT-05:

- `/usr/bin/ssh` runs as the user with their configuration, agent, keys, known hosts, `ProxyJump` and `ProxyCommand`. Keel doesn't implement SSH and never edits SSH configuration.
- Tunnels are `ssh -N` with a Unix-socket local forward in an owner-only runtime directory ([Architecture](architecture.md#ssh-tunnels)).
- Each tunnel is its own foreground ssh: Keel passes `ControlMaster=no`, `ControlPath=none`, `ControlPersist=no` and `ForkAfterAuthentication=no`, which override the user's config, so a shared master or a forked ssh never holds a Keel forward that Keel can't stop.
- A tunnel never opens a TCP port: when the user's config adds `LocalForward`, `RemoteForward` or `DynamicForward` for the destination (checked with `ssh -G` before each launch; the config files are read first, so `ssh -G` only runs when one sets a forward, and never when a `Match exec` would run a command — that case is unchecked), Keel doesn't start ssh and reports `TUNNEL_FAILED` naming the forwards.
- Saved SSH passwords: Keychain (`Keel SSH Host`), given to ssh only for its password prompt, once per tunnel, through `keel-askpass` with nonce and peer checks.
- Every other ssh prompt is relayed verbatim to the user; Keel never answers host-key prompts and never adds trust-bypass options.
- Discovery reads literal `Host` aliases from `~/.ssh/config` (no wildcards, no `Match`, never executes anything).

## Trellis

**INT-07 (P0).** Keel is a **completely independent app**.

- At run time Keel never reads or writes Trellis's state directory, settings, saved hosts or Keychain items, and doesn't call the Trellis CLI or API. Keel's SSH hosts come only from Keel's own host library and `~/.ssh/config`.
- **Source reuse only:** SSH hosts, discovery, askpass, owner-only storage and shortcut bindings are vendored from Trellis into `ThirdParty/TrellisShared` with `PROVENANCE.md`, and renamed to Keel identifiers.
- **Visual reuse:** Trellis's terminal colors for the console and its native graphite grays for the dark theme. Keel's accent (Redis red), light sidebar tint and fonts (Inter, JetBrains Mono) are its own ([Design](design/index.md)).
- Both apps can run at once without conflicts: separate bundle IDs, state directories and Keychain services. Keel never uses Trellis's port 7777.

## Keychain and LocalAuthentication

**INT-08 (P0).** Generic passwords for services `Keel Connection`, `Keel TLS`, `Keel SSH Host`, *when unlocked, this device only*. Optional per-profile "Require Touch ID to connect" uses LocalAuthentication before the password is read (enforced by Keel, as in Trellis FR-H07). Ad-hoc development builds may prompt for Keychain access again after a rebuild.

## Clipboard

**INT-10 (P0).** `NSPasteboard` only on explicit copy/paste. The clipboard is never polled. Pasting a connection URL is recognized only in the New Connection sheet (FR-CN08).

## Updates

**INT-11 (P0).** Sparkle 2 (pinned exact version), EdDSA-signed appcast and updates, HTTPS feed on the Bearstouch release host, `SUEnableSystemProfiling = NO`, automatic checks on by default with a user-visible toggle, user-confirmed installs. Release builds verify both the Developer ID signature and the EdDSA signature. See [MAC-08](macos.md).

- **Feed and key.** `release/manifest.json` → `sparkle`: Sparkle 2.10.0, the feed `https://bearstouch.com/keel/appcast.xml`, archives under `https://bearstouch.com/keel/releases/`, and the public EdDSA key (`SUPublicEDKey`). The private key lives in the release owner's login keychain (`generate_keys --account com.bearstouch.keel`) and, exported, in the `SPARKLE_ED_PRIVATE_KEY` repository secret; it never enters the repository. Without it installed copies can never accept another update, so it is backed up offline.
- **Info.plist** (`release/Info.plist`, checked by `UpdatePolicy`): `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks = YES` (so Sparkle never asks at launch), `SUScheduledCheckInterval = 86400`, `SUAllowsAutomaticUpdates = NO` and `SUAutomaticallyUpdate = NO` (every install waits for the user), `SUEnableSystemProfiling = NO`, `SURequireSignedFeed = YES`, `SUVerifyUpdateBeforeExtraction = YES`; no `SUSendProfileInfo`.
- **Updater.** Only a bundle with the installed identity, an HTTPS feed and a valid key has one, and never with `--fixture`: `swift run`, development builds and fixture launches show no **Check for Updates…** item and no update toggle, and never contact the feed. The user's choice (Settings → General → **Check for updates automatically**, `checksForUpdates` in `settings.json`) is put on the updater before it starts and on every Apply; profiling and automatic downloads are switched off then too, whatever Sparkle remembered.
- **Appcast.** `package-release.sh` writes `dist/appcast.xml` with one item (the version, minimum macOS, the archive's URL, length and EdDSA signature) and signs the feed in place. The release workflow attaches it to the GitHub release; publishing it and the archive on the feed host is a manual step until that host has a deploy path.

## Import and export

**INT-12 (P0).**

- Profiles and folders: versioned JSON, no secrets (FR-CN14).
- Values: single-key export to a file (FR-ED15). Multi-key export/import is P1.
- Importers for other clients (RedisInsight, Another Redis Desktop Manager, Medis) are P2; each must map only the fields it supports and list what it leaves out, and never import passwords into files.

### Profiles export file

File → **Export Connections…** writes one JSON object (`Keel Connections.json`, pretty-printed, sorted keys, at most 4 MiB):
`format` (`"keel-profiles"`), `schemaVersion` (integer, currently 1), `folders` (`id`, `name`, in display order) and
`profiles` (`id`, optional `folderID`, `settings` — exactly the editor's `ConnectionSettings`, in display order).
Nothing else: no password, passphrase, client identity, `hasPassword`, `hasTLSSecret`, revisions or collapse
state. IDs are kept in the file, so a re-import recognises the records it already holds. A saved-SSH-host tunnel keeps the host's
ID; on another Mac it resolves only if that host exists there. Export is refused while `connections.json` awaits
recovery or is read-only, so an empty or backup view never overwrites a good export.

File → **Import Connections…** reads the file off the main actor and checks, before anything is shown:
- a missing or different `format`, or `schemaVersion` < 1 → "This file isn't a Keel connections export.";
- a higher `schemaVersion` → "This file was exported by a newer version of Keel (format N). Update Keel to import it."
  (the version is read before the body, so unknown new fields never turn into a damaged-file error);
- more than 4 MiB → too large; any malformed record, repeated ID, folder reference outside the file or setting that
  fails the profile editor's validation → "This export is damaged (field), so nothing was imported."

The preview sheet then shows the counts ("3 connections and 1 folder."), the saved records whose IDs collide (at most
three named), and — only when there are collisions — the policy: **Skip existing** (preselected; never changes a saved
record), **Replace existing** (saved settings, folder and folder name take the file's values; a changed connection or
weakened transport removes the saved password, as an edit does; the TLS identity stays) or **Keep both** (the
imported profile is added with a new ID as "<name> (imported)"; folders are shared, never duplicated). New folders go
after the saved ones, new profiles at the end of their folder, in file order. An added profile always gets a **new
ID** and records the file's ID as `importedFrom` in `connections.json`: the `Keel Connection` / `Keel TLS` items are
keyed by profile ID and shared by every Keel copy on the Mac (installed, development, `--state-directory`,
`--fixture`), so keeping the file's ID would let deleting or editing the import remove or overwrite the source copy's
secrets. A record collides with a saved profile of its ID or one imported under it, so re-importing the same file still
matches; folders keep their IDs (no secret is keyed by them). Import is one store commit: Keychain
removals are staged and undone if the metadata write fails, so a failure leaves every profile, folder and Keychain
item as it was and the sheet stays open with the reason. An import that changes nothing (Skip on a re-import)
writes nothing and keeps the store revision.

## Dependencies

| Dependency | Use | Policy |
| --- | --- | --- |
| Sparkle 2 | Updates | SwiftPM, exact version, checksum verified; MIT |
| `ThirdParty/TrellisShared` | Vendored Bearstouch code | Provenance and local patches recorded |
| JetBrains Mono | Console and data font | OFL 1.1, bundled, registered for the process only |
| Inter | Interface font | OFL 1.1, bundled, registered for the process only |
| Redis / Valkey / Dragonfly containers | Integration tests only | Pinned image digests in CI |
| OpenSSH | Tunnels | The system's own |

# Changelog

All notable changes to Keel are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Swift package scaffold with the Keel targets, an empty Keel window, launch arguments `--state-directory`,
  `--no-mcp` and `--fixture`, owner-only state folder, release manifest, formatter config and CI (KEEL-001).
- Vendored Trellis code in `ThirdParty/TrellisShared` with `PROVENANCE.md`: SSH host library and `~/.ssh/config`
  discovery, the askpass broker and `keel-askpass` helper, owner-only file storage, rebindable shortcut rules and the
  MCP HTTP parser and listener, all under Keel names (`Keel SSH Host`, `SSH_ASKPASS_KEEL_*`) (KEEL-002).
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

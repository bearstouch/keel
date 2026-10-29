# Changelog

All notable changes to Keel are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.1] - 2026-10-29

### Added

- Keel is now licensed under the MIT License (`LICENSE`); the app bundles it as `Contents/Resources/LICENSE.txt`.
- Client certificates (`.p12` or PEM) can be imported, shown and removed from the connection sheet's TLS row.
- Auto-page and Pause Scanning in the key list's ⋯ menu.

### Changed

- A second launch against the same state folder brings the running Keel forward and exits with status 75.
- Imported profiles get new IDs, so two Keel copies never share a profile's Keychain items.
- A tunnel whose `~/.ssh/config` adds `LocalForward`, `RemoteForward` or `DynamicForward` is refused with
  `TUNNEL_FAILED`; Keel's ssh also ignores `ControlMaster`, `ControlPersist` and `ForkAfterAuthentication`.

### Fixed

- Switching between connected tabs showed the previous tab's console and key list, so commands could reach the
  wrong server.
- Refresh, another selection, a database switch or a filter discarded an editor's unsaved changes; Keel now keeps the
  draft on Refresh and asks Save / Don't Save / Cancel otherwise.
- A saved Redis password stayed in use after its saved SSH host was re-pointed elsewhere.
- `EXEC` ran writes queued before a profile was made read-only; the console's size warning no longer queues reads
  inside `MULTI`.
- Bracketed IPv6 hosts (`[::1]`) now connect, and no IP literal is sent as the TLS server name.
- An SSH prompt answer always goes to the prompt on screen.
- The filter help no longer offers `[!a]` as negation (only `[^a]` negates).
- Typing in hash and set editors no longer re-sorts every row on each keystroke.
- The forward check before an SSH tunnel never runs the user's `Match exec` commands.
- Console masking no longer leaks a password for a quoted `"AUTH"` or for `HELLO … SETNAME auth AUTH user pass`.
- Bulk delete refuses every pattern that matches all keys (such as `?*`), matches globs exactly like Redis and
  Valkey, and reports keys the server matched but Keel left instead of saying "complete".
- `--fixture` runs never read or write the login Keychain, and their Remove Keel Data never touches it.
- Single-dash spellings of Keel's flags (`-fixture`, `-state-directory`) exit with 64 instead of launching.
- A saved SSH host password is not replaced when the old one can't be read from the Keychain.
- Closing a tab while it connects cancels the connect, its SSH tunnel start and its prompts.
- Deleting a profile lists the tabs it closes and asks before discarding their unsaved changes.
- A server's keyboard-interactive text is never shown as a host-key question.
- An EC private key that doesn't match the certificate is refused at import.
- A hash deleted just before it opens is reported as gone; sorted set scores that overflow a double are refused.
- Key names escape bidi marks and line separators; hostile INFO memory figures no longer crash Info.

## [0.9.0] - 2026-10-27

First release of Keel, a native Redis client for macOS. Supports Redis 6.0+, Valkey 7.2–9.x and Dragonfly.

### Added

- **Connections**: profiles and folders in a sidebar, `redis://` / `rediss://` URL paste, Test before saving,
  import and export without secrets. Passwords live only in the Keychain.
- **TLS and SSH**: TLS 1.2+ with custom CAs and client certificates; SSH tunnels through the system `ssh`, using
  `~/.ssh/config` hosts, with host keys and other prompts shown in the app.
- **Key browser**: SCAN only, never `KEYS`, and smooth with millions of keys. Namespace tree or flat list, pattern and
  type filters, live TTLs, a database switcher and binary-safe key names.
- **Editors** for strings, hashes, lists, sets, sorted sets and streams, with paging for large values; Text, JSON,
  Hex and Raw viewers; rename, TTL, delete, export and new key. Saves are atomic and detect conflicts.
- **Console**: redis-cli-style output, history, completion with argument hints, MONITOR / SUBSCRIBE, and
  credentials masked.
- **Info**: memory, clients, ops/sec and uptime at a glance, databases, health and every INFO field.
- **Production safety**: read-only connections, a production strip, typed confirmations for multi-key delete and
  FLUSH, and bulk delete by pattern in throttled batches you can cancel.
- **macOS app**: multiple windows and tabs, command palette (⌘K), rebindable shortcuts, Light / Dark / System themes,
  Settings, welcome screen, VoiceOver support, About Keel and Remove Keel Data….
- **Privacy**: no telemetry; values, key names and console output are never logged.
- **Distribution**: a signed Universal 2 DMG with automatic updates through Sparkle.

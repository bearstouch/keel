# Changelog

All notable changes to Keel are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Keel is now licensed under the MIT License (`LICENSE`); the app bundles it as `Contents/Resources/LICENSE.txt`.

## [0.9.0] - Unreleased

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

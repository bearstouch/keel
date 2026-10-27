# Keel

Keel is a calm, native Redis client for macOS by Bearstouch. It browses millions of keys with SCAN only, edits every
core type, has a redis-cli-style console and an INFO overview, and keeps production safe with read-only connections,
typed confirmations and batched bulk deletes. It supports Redis 6.0+, Valkey 7.2–9.x and Dragonfly on macOS 14 or
later.

Keel is a completely independent app. Some code is vendored from its sibling Trellis at build time; nothing is shared
at run time.

## Where to start

| If you want to… | Read |
| --- | --- |
| Understand what Keel is for and what's in scope | [Product overview](overview.md) |
| Build, run and test it | [Getting started](development/getting-started.md) |
| Learn how it's put together | [Architecture](architecture.md) |
| Know the rules every change must keep | [Development rules](development/rules.md) |
| Make a change | [Change workflow](development/workflow.md) |
| Look up a type or module | [API reference](api/index.md) |
| Check what a feature must do | [Requirements](requirements/index.md) |
| Work on UI | [Design](design/index.md) |
| See what's done and what's pending | [Project status](project/status.md) |

## Documentation map

- **Product:** [overview](overview.md), with users, vocabulary, scope, milestones and decisions.
- **Architecture:** [architecture](architecture.md), with modules, the single data path, safety policy, connections,
  TLS, SSH tunnels, key index, threading, persistence, secrets, errors and reuse from Trellis.
- **Requirements:** [functional](requirements/functional.md) and [non-functional](requirements/non-functional.md)
  requirements with stable IDs and acceptance checks.
- **Integrations:** [servers, protocol, URLs, TLS, OpenSSH, Keychain, updates, import/export](integrations.md).
- **Platform:** [macOS support](macos.md), covering distribution, signing, permissions and release verification.
- **Design:** the [visual contract](design/index.md) and its [canvas sources](design/sources.md).
- **API:** module references for [KeelRESP](api/resp.md), [KeelSSH](api/ssh.md), [KeelCore](api/core.md),
  [KeelUI](api/ui.md), and [KeelRelease and KeelApp](api/release.md).
- **Development:** [getting started](development/getting-started.md), [rules](development/rules.md),
  [testing](development/testing.md), [workflow](development/workflow.md), [releasing](development/releasing.md).

## Core ideas

1. **Safe by default.** SCAN, never KEYS. Writes honor read-only. Destructive operations need typed confirmation.
2. **One data path.** Editors, browser, console and bulk jobs all go through one command service and one safety
   policy.
3. **Bytes, not strings.** Keys and values round-trip byte-exactly.
4. **Honest state.** Keel reports what the server returned and never guesses.
5. **Show less, reveal on demand.** Each screen shows only what the current task needs.
6. **Native calm.** SwiftUI chrome and AppKit where performance needs it; no webview.

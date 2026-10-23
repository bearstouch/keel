# Keel specifications

Keel is a native Swift Redis client for macOS by Bearstouch, a sibling of Trellis and PostWoman. These pages are the **behavior contract**: code follows the specs, and when a spec is ambiguous the ambiguity is resolved in the spec, not invented in code.

| Page | Contents |
| --- | --- |
| [01 Overview](01-overview.md) | Purpose, users, vocabulary, scope and priorities, primary interaction, definition of done, milestones, decisions and open questions |
| [02 Architecture](02-architecture.md) | Modules, the single data path, the Redis client, connections and tunnels, key index, threading, persistence, secrets, reuse from Trellis |
| [03 Functional requirements](03-functional-requirements.md) | Connections, key browser, value editors, console, safety, server info, app basics (`FR-…`) |
| [04 Non-functional requirements](04-non-functional-requirements.md) | Performance, memory, reliability, security, privacy, accessibility, quality (`NFR-…`) |
| [06 Integrations](06-integrations.md) | Redis-compatible servers, protocol, TLS, OpenSSH, Keychain, Trellis, updates (`INT-…`) |
| [07 macOS support](07-macos-support.md) | Platform, distribution, signing, permissions, installation (`MAC-…`) |
| [08 Design](08-design.md) | Visual contract: palettes, type, layout, components, screens; design sources in [`design/`](design/) |
| [Stories](stories/README.md) | 52 implementation stories with acceptance criteria and unit tests, epics, sprint plan, definition of done |

## Requirement IDs

IDs are stable. Don't renumber or reuse them; new requirements get new IDs and retired ones are marked **retired**.

| Prefix | Area | Page |
| --- | --- | --- |
| `FR-CN` | Connections | 03 |
| `FR-KB` | Key browser | 03 |
| `FR-ED` | Value editors | 03 |
| `FR-CO` | Console | 03 |
| `FR-SF` | Safety | 03 |
| `FR-SI` | Server info | 03 |
| `FR-AP` | App basics | 03 |
| `NFR-…` | Non-functional | 04 |
| `INT-…` | Integrations | 06 |
| `MAC-…` | macOS | 07 |
| `DS-…` | Design | 08 |

Priorities: **P0** is v1 (the first public release), **P1** is the next release, **P2** is later. Acceptance checks stay unchecked until they are actually observed; manual checks that can't be run (VoiceOver, notarization on a clean machine, Intel hardware) are recorded as **pending**, never as passed.

### Retired IDs

Retired 2026-10: agent API and MCP server removed from v1; numbers are never reused.

| IDs | Was |
| --- | --- |
| `FR-RC01`–`FR-RC08` | Remote control (MCP settings), 03 §8 |
| `API-01`–`API-10` | Agent API, the former page 05 |
| `NFR-SC06` | MCP server transport controls |
| `INT-09` | Agents and MCP clients |
| `MAC-15` | Firewall prompt for a non-loopback MCP bind |
| Stories `KEEL-043`–`KEEL-047` | Grants, agent tool catalog, MCP server, approvals, Agents settings |

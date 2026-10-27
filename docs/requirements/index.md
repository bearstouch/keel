# Requirements

The requirement pages are Keel's **behavior contract**. Code follows them. When a page is ambiguous, fix the page;
don't invent behavior in code that conflicts with it. A behavior change updates the relevant page in the same change,
with new requirement IDs and acceptance checks ([NFR-QA05](non-functional.md#quality-and-maintainability)).

| Page | Contents | IDs |
| --- | --- | --- |
| [Functional requirements](functional.md) | Connections, key browser, value editors, console, safety, server info, app basics, default shortcuts | `FR-…` |
| [Non-functional requirements](non-functional.md) | Performance, memory, reliability, security, privacy, accessibility, usability, quality | `NFR-…` |
| [Integrations](../integrations.md) | Redis-compatible servers, protocol, URLs, TLS, OpenSSH, Trellis, Keychain, updates, import/export | `INT-…` |
| [macOS support](../macos.md) | Platform, native behavior, distribution, signing, permissions, installation, release verification | `MAC-…` |
| [Design](../design/index.md) | Palettes, typography, layout, components, app icon, screens | `DS-…` |

## Requirement IDs

IDs are stable. Never renumber or reuse them. New requirements get new IDs, and retired ones are marked **retired**.

| Prefix | Area | Page |
| --- | --- | --- |
| `FR-CN` | Connections | [Functional](functional.md#1-connections) |
| `FR-KB` | Key browser | [Functional](functional.md#2-key-browser) |
| `FR-ED` | Value editors | [Functional](functional.md#3-value-editors) |
| `FR-CO` | Console | [Functional](functional.md#4-console) |
| `FR-SF` | Safety | [Functional](functional.md#5-safety) |
| `FR-SI` | Server info | [Functional](functional.md#6-server-info) |
| `FR-AP` | App basics | [Functional](functional.md#7-app-basics) |
| `NFR-…` | Non-functional | [Non-functional](non-functional.md) |
| `INT-…` | Integrations | [Integrations](../integrations.md) |
| `MAC-…` | macOS | [macOS support](../macos.md) |
| `DS-…` | Design | [Design](../design/index.md) |

## Priorities

**P0** is v1 (the first public release), **P1** is the next release and **P2** is later. Requirements are P0 unless
marked otherwise.

## Acceptance checks

Every requirement has an acceptance check. A check counts as passed only when it has actually been observed. Manual
checks that can't be run yet (VoiceOver, notarization on a clean machine, Intel hardware, managed cloud Redis) are
recorded as **pending**, never as passed. The checks still pending are listed in
[Project status](../project/status.md#pending-verification).

### Retired IDs

Retired 2026-10: the agent API and MCP server were removed from v1. These numbers are never reused.

| IDs | Was |
| --- | --- |
| `FR-RC01`–`FR-RC08` | Remote control (MCP settings), functional requirements §8 |
| `API-01`–`API-10` | Agent API, a former requirements page |
| `NFR-SC06` | MCP server transport controls |
| `INT-09` | Agents and MCP clients |
| `MAC-15` | Firewall prompt for a non-loopback MCP bind |

# KEEL-042 · Server info overview

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E5 Console and server info | P0 | 5 pts | S7 | [KEEL-011](KEEL-011-server-detection-capability-probes-and-minimum-version.md), [KEEL-026](KEEL-026-windows-connection-tabs-and-modes.md) |

**Specs:** [FR-SI01–FR-SI05](../03-functional-requirements.md#6-server-info), [08 Design → Screens](../08-design.md#screens)

## Story

As an operator, I want a simple health overview with all INFO details one click away, so that I can check a server at a glance.

## Scope

- INFO parser (all sections, unknown fields kept)
- Overview: Memory (with bar), Clients, Operations/sec, Uptime tiles; Databases (Browse) and Health lists
- Show all INFO fields: sections + searchable Raw
- Auto-refresh menu (off, 2/5/10/30 s) only while visible; ⌘R

## Acceptance criteria

- [ ] **AC1.** Every INFO field appears under Show all, including unknown ones.
- [ ] **AC2.** Auto-refresh sends INFO only while Info mode is visible.
- [ ] **AC3.** Missing permission shows "unavailable" per section.
- [ ] **AC4.** Matches the `Info` boards (manual design review).

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `InfoParserTests.testParsesAllSections` | fixtures per server |
| `InfoParserTests.testKeepsUnknownFields` | Keeps unknown fields |
| `InfoOverviewTests.testTileValues` | memory %, ops/s, uptime formatting |
| `InfoRefreshTests.testOnlyWhileVisible` | injected clock |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

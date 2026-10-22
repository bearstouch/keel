# KEEL-041 · Console view: history, completion, streaming, masking

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E5 Console and server info | P0 | 8 pts | S7 | [KEEL-040](KEEL-040-console-parser-and-redis-cli-formatter.md), [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md), [KEEL-012](KEEL-012-command-catalog.md) |

**Specs:** [FR-CO01, FR-CO04–FR-CO10](../03-functional-requirements.md#4-console), [08 Design → Console](../08-design.md#console-both-themes)

## Story

As a power user, I want a dark redis-cli-style console with history, completion and streaming commands, so that I can work on the server without leaving Keel.

## Scope

- `ConsoleTextView` (AppKit) with Trellis terminal colors, JetBrains Mono 14, Redis-red cursor; own connection; prompt `host:port[db]>`
- History (memory only, 1,000, ↑/↓, ⌃R); completion list (names only) + inline argument hint; ⌥⌘K / ⌃L clear
- MONITOR / SUBSCRIBE on a stream connection with Stop (⌘.) and 10,000-line bound; blocking commands cancellable
- Masking of AUTH-type arguments in echo and history; safety policy errors printed as `(error) KEEL_…`

## Acceptance criteria

- [ ] **AC1.** `SELECT 3` changes only the console's db and prompt.
- [ ] **AC2.** `HSC` + Tab completes `HSCAN` and shows its syntax hint.
- [ ] **AC3.** Stop ends MONITOR within 1 s.
- [ ] **AC4.** `AUTH secret` appears as `AUTH ••••••` in echo and history.
- [ ] **AC5.** Console output is never written to disk or logs.
- [ ] **AC6.** Matches the `Console` boards (manual design review).

## Unit tests

Test target: `KeelCoreTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ConsoleSessionTests.testSelectIsConsoleScoped` | Select is console scoped |
| `ConsoleHistoryTests.testDedupAndLimit` | Dedup and limit |
| `ConsoleHistoryTests.testReverseSearch` | Reverse search |
| `ConsoleCompletionTests.testCompletesCommandsAndSubcommands` | Completes commands and subcommands |
| `ConsoleMaskingTests.testMasksCredentialArguments` | AUTH, HELLO AUTH, ACL SETUSER, CONFIG SET requirepass, MIGRATE AUTH |
| `ConsoleStreamingTests.testStopEndsMonitor` | Stop ends monitor |
| `ConsoleStreamingTests.testOutputIsBounded` | Output is bounded |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

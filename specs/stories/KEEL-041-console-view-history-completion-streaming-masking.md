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

- [x] **AC1.** `SELECT 3` changes only the console's db and prompt.
- [x] **AC2.** `HSC` + Tab completes `HSCAN` and shows its syntax hint.
- [x] **AC3.** Stop ends MONITOR within 1 s.
- [x] **AC4.** `AUTH secret` appears as `AUTH ••••••` in echo and history.
- [x] **AC5.** Console output is never written to disk or logs.
- [ ] **AC6.** Matches the `Console` boards (manual design review).

### Verification notes

- AC1 observed in `ConsoleSessionTests.testSelectIsConsoleScoped`: after `SELECT 3` the console's database is 3 and its prompt `127.0.0.1:6379[3]> `; its next `GET` runs on `console(id)` (trace `SELECT 3`, `GET k`) while a browser `GET` opens and runs on `browser(db0)`. The tab's browser database is a separate model value the console never writes.
- AC2 observed in `ConsoleCompletionTests.testCompletesCommandsAndSubcommands` with the bundled catalog: `HSC` lists only `HSCAN`, the hint reads `AN key cursor [MATCH pattern] [COUNT count] [NOVALUES]`, Tab gives `HSCAN` and the hint ` key cursor [MATCH pattern] [COUNT count] [NOVALUES]`; `CLIENT LI` → `CLIENT LIST`, `XINFO ST` → `XINFO STREAM`.
- AC3 observed in `ConsoleStreamingTests.testStopEndsMonitor` against the in-memory server: MONITOR's `OK` and an injected MONITOR line arrive through the stream; `stopStream()` closes the stream connection and returns in well under 1 s, the stream reports ended and the next `PING` runs. In the app the drain notices the end within 50 ms and the prompt returns. Also observed once against a throwaway local **redis-server 7.2.1** (temporary test, not committed): SELECT 3 scoped to the console, MONITOR printed another client's `GET`, Stop returned in < 1 ms, SUBSCRIBE received a PUBLISH, `BLPOP nolist 0` was cancelled (`KEEL_OUTCOME_UNKNOWN`) and the next command reconnected on db3. The pinned container matrix (Valkey included) is KEEL-048.
- AC4 observed in `ConsoleMaskingTests.testMasksCredentialArguments` (AUTH, HELLO AUTH, ACL SETUSER `>`/`<`/`#`, CONFIG SET requirepass/masterauth, MIGRATE AUTH/AUTH2, an unparsable `AUTH "secret`) and `ConsoleModelTests.testAuthIsMaskedInEchoHistoryAndView`: the server receives `AUTH secret`, the buffer and the profile's history hold `AUTH ••••••`, and the text view's string contains no `secret`.
- AC5 observed by inspection: no console type (`ConsoleSession`, `ConsoleBuffer`, `ConsoleHistory`, `ConsoleModel`, `ConsoleTextView`) calls `os_log`/`Logger`/`print` or writes a file; history and scrollback live only in memory (`ConsoleHistoryBook` is not part of any persisted document). The automated logging guard is KEEL-046.
- AC6 **pending**: light/dark review against the `Console` / `ConsoleDark` boards in the running app (needs a server to connect to). Known differences to review: the prompt is the redis-cli `host:port[db]>` text (FR-CO01) where the canvas abbreviates `›`, and Stop floats at the top right while a command or stream runs.
- Review fixes (`ConsoleReviewTests`): Stop during an FR-SF08 size read no longer lets the command go out afterwards; a stream the server refuses (`NOPERM` on MONITOR) ends by itself; `tls-key-file-pass` / `tls-client-key-file-pass` are masked too.
- Follow-ups (from review, not applied): Return while a command runs drops the typed line; after `MULTI … SELECT n … EXEC` the prompt keeps the old db (data commands fail safe with "run SELECT first"); `removeFirst` trimming is O(n) per batch (a ring buffer would be cheaper under heavy MONITOR); drops inside the connection's stream buffer aren't counted in the "lines skipped" notice; a lone `UNSUBSCRIBE` opens a stream. Unrelated, found while testing: a Unix-socket path over 104 bytes traps in Network.framework (transport, pre-existing).
- Pending (not in this story's scope or not possible here): ⌘+/⌘− zoom of the console font (FR-CO08) and the Settings → Console options (FR-AP09) are not built; VoiceOver pass (KEEL-045).

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

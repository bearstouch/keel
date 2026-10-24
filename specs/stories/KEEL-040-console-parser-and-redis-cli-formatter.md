# KEEL-040 · Console parser and redis-cli formatter

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E5 Console and server info | P0 | 5 pts | S7 | [KEEL-004](KEEL-004-resp2-resp3-streaming-codec.md) |

**Specs:** [FR-CO02, FR-CO03](../03-functional-requirements.md#4-console), [NFR-QA04](../04-non-functional-requirements.md#quality-and-maintainability)

## Story

As a power user, I want the console to read and print commands exactly like redis-cli, so that my muscle memory works.

## Scope

- Input tokenizer: whitespace, double quotes with `\n \r \t \b \a \\ \" \xNN`, single quotes literal; unbalanced quotes error
- Formatter for RESP2 (`(integer)`, quoted strings, `(nil)`, `(error)`, `(empty array)`, nested numbering) and RESP3 (redis-cli 7 notation)

## Acceptance criteria

- [x] **AC1.** `SET k "a\x00b"` produces a 3-byte value. *(Observed: `ConsoleTokenizerTests.testEscapes` and the wire frame `$3\r\na\0b` through `DataCommandService` in `testNulEscapeIsSentAsThreeBytes`.)*
- [ ] **AC2.** Golden outputs match redis-cli 7.4 for the fixture command set. *(Observed against **redis-cli 7.2.1** (the local binary): all 37 RESP2 and 35 RESP3 cases match byte for byte. **Pending:** re-capture with a redis-cli 7.4 binary — `python3 -I scripts/capture-console-goldens.py --redis-server … --redis-cli …` — and re-run the tests; building 7.4 here wasn't permitted.)*
- [x] **AC3.** Unbalanced quotes show an inline error and send nothing. *(Observed in Core: `ConsoleParseError.unbalancedQuotes` with its inline message is thrown before any command exists; in the console (KEEL-041) `ConsoleModelTests.testParseErrorSendsNothingAndClearEmptiesTheView` prints `(error) Invalid argument(s): unbalanced quotes` and the server receives nothing.)*

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ConsoleTokenizerTests.testEscapes` | table |
| `ConsoleTokenizerTests.testSingleQuotesAreLiteral` | Single quotes are literal |
| `ConsoleTokenizerTests.testUnbalancedQuotes` | Unbalanced quotes |
| `RedisCliFormatterTests.testGoldenRESP2Outputs` | fixtures from redis-cli 7.4 |
| `RedisCliFormatterTests.testGoldenRESP3Outputs` | Golden RESP3 outputs |
| `RedisCliFormatterTests.testNestedArrayIndentation` | Nested array indentation |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

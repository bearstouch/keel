# KEEL-004 · RESP2/RESP3 streaming codec

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 5 pts | S1 | [KEEL-001](KEEL-001-package-scaffold-toolchain-and-ci.md) |

**Specs:** [INT-03](../06-integrations.md#protocol), [NFR-RL05](../04-non-functional-requirements.md#reliability-and-data-safety), [NFR-RS03](../04-non-functional-requirements.md#memory-and-resources)

## Story

As the connection layer, I want a byte-exact, bounded RESP parser and encoder, so that every reply is decoded correctly and a hostile server can't crash Keel.

## Scope

- `RESPValue` enum covering RESP2 (simple, error, integer, bulk, array, null) and RESP3 (map, set, double, boolean, big number, verbatim, push, attribute, null)
- Incremental `RESPParser` fed arbitrary chunks; `RESPEncoder` producing arrays of bulk strings from `[Data]`
- Limits: max reply 64 MiB, max nesting 128, max aggregate count; violations → `PROTOCOL_ERROR` / `LIMIT_EXCEEDED`

## Acceptance criteria

- [x] **AC1.** Every RESP type round-trips through encoder/parser byte-exactly, including binary bulk strings with `\r\n` and `\0` inside. *(Observed: `testRoundTripsEveryTypeByteExactly` over every canonical fixture, `testBinarySafeBulkStrings` with all 256 byte values. Non-canonical spellings the parser accepts (`:+7`, `,3`, `-nan`, `+inf`) decode to the same value but re-encode canonically.)*
- [x] **AC2.** Replies split at every possible byte boundary parse to the same value. *(Observed: `testChunkBoundariesProduceSameValue` — every offset, byte at a time, and a pipelined stream of all fixtures.)*
- [x] **AC3.** Invalid lengths, non-numeric integers, nesting > 128 or a bulk > 64 MiB fail with a typed error and never allocate the declared size up front. *(Observed: `testRejectsNegativeAndHugeLengths` (reserved capacity < 1 MiB for declared 60 MB / 4M elements), `testRejectsExcessiveNesting`, `testRejectsMalformedFrames`, and `RESPReviewTests` — attribute chains count toward nesting.)*
- [x] **AC4.** A fuzz run of at least 1,000,000 random and mutated inputs completes without crash or hang (CI job). *(Observed locally: `testRandomInputsNeverCrash`, 1M seeded cases in ~13 s debug, runs in CI's `swift test` step. **Pending:** first green run on the `macos-26` runner for this PR.)*

## Unit tests

Test target: `KeelRESPTests`.

| Test | Verifies |
| --- | --- |
| `RESPParserTests.testParsesEveryRESP2Type` | table of canonical frames |
| `RESPParserTests.testParsesEveryRESP3Type` | maps, sets, doubles incl. inf/nan, booleans, verbatim, push |
| `RESPParserTests.testChunkBoundariesProduceSameValue` | split each fixture at all offsets |
| `RESPParserTests.testBinarySafeBulkStrings` | CRLF and NUL inside values |
| `RESPParserTests.testRejectsNegativeAndHugeLengths` | no up-front allocation |
| `RESPParserTests.testRejectsExcessiveNesting` | 129 nested arrays → error |
| `RESPEncoderTests.testEncodesArgumentsAsBulkArray` | exact bytes for `SET k v` |
| `RESPFuzzTests.testRandomInputsNeverCrash` | seeded fuzz, bounded time |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

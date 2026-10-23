# KEEL-012 · Command catalog

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 3 pts | S1 | [KEEL-004](KEEL-004-resp2-resp3-streaming-codec.md) |

**Specs:** [02 Architecture → Safety policy](../02-architecture.md#safety-policy), [INT-03](../06-integrations.md#protocol)

## Story

As the safety policy and the console, I want every command's flags, arity, key positions and docs, so that commands can be classified and completed reliably.

## Scope

- Bundled catalog generated from Redis 7.4 and Valkey 8, checked against Valkey 9 (`Resources/Commands`, versioned) with flags `write`, `readonly`, `admin`, `dangerous`, `blocking`, `pubsub`
- Live catalog from `COMMAND INFO` / `COMMAND DOCS` when available, merged over the bundled one
- Subcommands (`CLIENT LIST`, `XINFO STREAM`)

## Acceptance criteria

- [x] **AC1.** Every command used by Keel's editors is present and classified.
- [x] **AC2.** `SET` is write, `GET` read, `FLUSHALL` write+dangerous, `SUBSCRIBE` pubsub, `BLPOP` blocking.
- [x] **AC3.** Unknown commands resolve to `.unknown` (never to read).
- [x] **AC4.** Docs give argument syntax for completion hints.

**Verification (KEEL-012).** AC1–AC4 observed in `CommandCatalogTests` against the bundled catalog (388 commands,
generated from Redis 7.4.11 and Valkey 8.1.10, checked against Valkey 9.0.6). AC1 uses the browser and editor command
list from 03 Functional requirements; it grows as the editors land (KEEL-028 onward). The bundled key ranges and
flags were compared with a local Redis 7.2.1 `COMMAND` reply (370 commands, identical arity and key ranges; only
`WAIT`/`WAITAOF` differ: 7.4 flags them `blocking`, 7.2.1 doesn't), and the live parser runs on captured Redis 7.2
`COMMAND INFO` / `COMMAND DOCS` frames over RESP2 and RESP3 (`Tests/Fixtures/Commands`). Live loading against Valkey
and Dragonfly is **pending** the integration matrix (KEEL-048).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `CommandCatalogTests.testEditorCommandsAreClassified` | Editor commands are classified |
| `CommandCatalogTests.testFlagsForReferenceCommands` | table |
| `CommandCatalogTests.testUnknownCommandFailsClosed` | Unknown command fails closed |
| `CommandCatalogTests.testLiveCatalogOverridesBundled` | Live catalog overrides bundled |
| `CommandCatalogTests.testSubcommandLookup` | Subcommand lookup |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

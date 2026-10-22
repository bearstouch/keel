# KEEL-012 · Command catalog

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 3 pts | S1 | [KEEL-004](KEEL-004-resp2-resp3-streaming-codec.md) |

**Specs:** [02 Architecture → Safety policy](../02-architecture.md#safety-policy), [INT-03](../06-integrations.md#protocol)

## Story

As the safety policy and the console, I want every command's flags, arity, key positions and docs, so that commands can be classified and completed reliably.

## Scope

- Bundled catalog generated from Redis 7.4 and Valkey 8 (`Resources/Commands`, versioned) with flags `write`, `readonly`, `admin`, `dangerous`, `blocking`, `pubsub`
- Live catalog from `COMMAND INFO` / `COMMAND DOCS` when available, merged over the bundled one
- Subcommands (`CLIENT LIST`, `XINFO STREAM`)

## Acceptance criteria

- [ ] **AC1.** Every command used by Keel's editors is present and classified.
- [ ] **AC2.** `SET` is write, `GET` read, `FLUSHALL` write+dangerous, `SUBSCRIBE` pubsub, `BLPOP` blocking.
- [ ] **AC3.** Unknown commands resolve to `.unknown` (never to read).
- [ ] **AC4.** Docs give argument syntax for completion hints.

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

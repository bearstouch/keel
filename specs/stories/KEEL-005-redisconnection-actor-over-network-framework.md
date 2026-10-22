# KEEL-005 · RedisConnection actor over Network.framework

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 8 pts | S1 | [KEEL-004](KEEL-004-resp2-resp3-streaming-codec.md) |

**Specs:** [02 Architecture → Connections](../02-architecture.md#connections), [NFR-RL03](../04-non-functional-requirements.md#reliability-and-data-safety)

## Story

As the app, I want one actor per server socket that pipelines commands with timeouts and bounded reads, so that browsing, editing and agents share a reliable transport.

## Scope

- `RedisConnection` actor wrapping `NWConnection` (TCP and Unix socket endpoints), injected `Transport` protocol for tests
- FIFO of pending replies (pipelining), per-command timeout, connect timeout, cancellation
- State: connecting → ready → failed/closed; drop handling reports in-flight commands as `OUTCOME_UNKNOWN` for writes and retries nothing

## Acceptance criteria

- [ ] **AC1.** 100 pipelined commands receive their replies in order.
- [ ] **AC2.** A command exceeding its timeout fails with `TIMEOUT` and the connection is closed (no late reply is attributed to the next command).
- [ ] **AC3.** If the socket drops after a write was sent, the caller gets `OUTCOME_UNKNOWN`; nothing is re-sent.
- [ ] **AC4.** Unix-socket endpoints work (used by SSH tunnels).
- [ ] **AC5.** No value or argument bytes are logged.

## Unit tests

Test target: `KeelRESPTests`.

| Test | Verifies |
| --- | --- |
| `RedisConnectionTests.testPipelinedRepliesKeepOrder` | fake transport |
| `RedisConnectionTests.testTimeoutClosesConnection` | injected clock |
| `RedisConnectionTests.testDropAfterWriteReportsOutcomeUnknown` | no resend |
| `RedisConnectionTests.testCancellationFailsPendingCommands` | cancel mid-flight |
| `RedisConnectionTests.testConnectsToUnixSocketEndpoint` | temp socket server |

## Integration and manual checks

- Against a local Redis 7.4 container: 10,000 pipelined `PING`s succeed.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

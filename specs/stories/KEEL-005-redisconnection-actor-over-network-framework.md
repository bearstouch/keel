# KEEL-005 · RedisConnection actor over Network.framework

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 8 pts | S1 | [KEEL-004](KEEL-004-resp2-resp3-streaming-codec.md) |

**Specs:** [02 Architecture → Connections](../02-architecture.md#connections), [NFR-RL03](../04-non-functional-requirements.md#reliability-and-data-safety)

## Story

As the app, I want one actor per server socket that pipelines commands with timeouts and bounded reads, so that browsing, editing, the console and bulk jobs share a reliable transport.

## Scope

- `RedisConnection` actor wrapping `NWConnection` (TCP and Unix socket endpoints), injected `Transport` protocol for tests
- FIFO of pending replies (pipelining), per-command timeout, connect timeout, cancellation
- State: connecting → ready → failed/closed; drop handling reports in-flight commands as `OUTCOME_UNKNOWN` for writes and retries nothing

## Acceptance criteria

- [x] **AC1.** 100 pipelined commands receive their replies in order. *(Observed: `testPipelinedRepliesKeepOrder` — the fake server holds replies until all 100 are in flight, then answers in 7-byte chunks; 1,000 pipelined binary `ECHO`s over a real Unix socket in `testConnectsToUnixSocketEndpoint`.)*
- [x] **AC2.** A command exceeding its timeout fails with `TIMEOUT` and the connection is closed (no late reply is attributed to the next command). *(Observed: `testTimeoutClosesConnection` with the injected clock — other in-flight commands settle, the transport is cancelled, the next send is `NOT_CONNECTED` and writes nothing; `RedisConnectionReviewTests.testTimerFiringAfterReplyLeavesConnectionReady`.)*
- [x] **AC3.** If the socket drops after a write was sent, the caller gets `OUTCOME_UNKNOWN`; nothing is re-sent. *(Observed: `testDropAfterWriteReportsOutcomeUnknown` — the wire holds exactly the original two frames.)*
- [x] **AC4.** Unix-socket endpoints work (used by SSH tunnels). *(Observed: `testConnectsToUnixSocketEndpoint` against a temporary BSD-socket server; `testMissingUnixSocketFailsToConnect`.)*
- [x] **AC5.** No value or argument bytes are logged. *(Observed: `KeelRESP` has no logging at all, enforced by `testProtocolLayerNeverLogs`; errors carry only OS codes.)*

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

- Against a local Redis 7.4 container: 10,000 pipelined `PING`s succeed. *(**Pending:** Docker was unresponsive here. Observed instead against a disposable local `redis-server` 7.2.1 on a temporary port: `KEEL_INTEGRATION=1 KEEL_INTEGRATION_REDIS_PORT=<port> swift test --filter RedisConnectionIntegrationTests` — 10,000 pipelined `PING`s over TCP in 0.18 s.)*

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

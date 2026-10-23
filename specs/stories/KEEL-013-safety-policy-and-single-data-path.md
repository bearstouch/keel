# KEEL-013 · Safety policy and single data path

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 8 pts | S2 | [KEEL-012](KEEL-012-command-catalog.md), [KEEL-006](KEEL-006-handshake-authentication-and-error-categories.md) |

**Specs:** [02 Architecture → One data path](../02-architecture.md#one-data-path), [FR-SF01](../03-functional-requirements.md#5-safety), [API-04](../05-api.md#requirements)

## Story

As a user of a production server, I want every command — from editors, console, bulk jobs or agents — to pass through one policy before it is sent, so that read-only and confirmations can never be bypassed.

## Scope

- `DataCommandService.execute(_:origin:context:)` with origins `.editor`, `.browser`, `.console`, `.bulk`, `.agent(grantID)`
- `SafetyPolicy.evaluate` returning allow / `READ_ONLY` / `BLOCKED_COMMAND` / `CONFIRMATION_REQUIRED` / `APPROVAL_REQUIRED` per the architecture table
- Typed editor operations compiled to commands and classified the same way
- `ServerSession` routes to connection roles (`browser`, `console`, `stream`, `job`, `agent`)

## Acceptance criteria

- [x] **AC1.** On a read-only profile, every write path (typed op, console text, bulk job, agent) is rejected and a protocol trace shows nothing sent.
- [x] **AC2.** `EVAL_RO`/`FCALL_RO` are allowed on read-only; `EVAL` is blocked.
- [x] **AC3.** Multi-key `DEL`, `FLUSHDB`, `FLUSHALL` require confirmation (UI) or approval (agent).
- [x] **AC4.** Admin commands, `KEYS`, `MONITOR`, `SUBSCRIBE` and unknown commands are always blocked for agents.
- [x] **AC5.** A blocked call returns its error without touching the socket.

**Verification (KEEL-013).** AC1–AC5 observed in `SafetyPolicyTests` and `DataCommandServiceTests`.
- AC1 covers typed editor operations, console argument arrays, bulk `UNLINK` batches and agent commands on a read-only
  profile. The `RecordingTransport` protocol trace shows no connection opened and no frame written. Console *text* is
  tokenized by KEEL-040, so its tokens reach this path as arguments.
- AC3 is observed at the policy level (`CONFIRMATION_REQUIRED` with the FR-SF03 typed text, `APPROVAL_REQUIRED` for
  agents). The sheets (KEEL-038) and the approval card (KEEL-046) are later stories.
- Pending against real servers (integration matrix, KEEL-053). Out of scope: MULTI/EXEC for editor multi-step edits
  (KEEL-027), the stream connection's push handling (KEEL-041), and opening real connections from profiles
  (KEEL-014/016: `ServerSession` takes an injected opener).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `SafetyPolicyTests.testReadOnlyBlocksEveryWriteOrigin` | matrix of origins × commands |
| `SafetyPolicyTests.testReadOnlyScriptsAllowed` | EVAL_RO / FCALL_RO |
| `SafetyPolicyTests.testDestructiveNeedsConfirmationOrApproval` | Destructive needs confirmation or approval |
| `SafetyPolicyTests.testAgentsBlockedFromAdminAndStreaming` | Agents blocked from admin and streaming |
| `SafetyPolicyTests.testUnknownCommandBlockedOnReadOnly` | fail closed |
| `DataCommandServiceTests.testBlockedCommandSendsNothing` | fake transport records zero writes |
| `DataCommandServiceTests.testRoutesToConnectionRoles` | Routes to connection roles |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

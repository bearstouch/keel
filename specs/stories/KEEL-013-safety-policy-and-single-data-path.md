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

- [ ] **AC1.** On a read-only profile, every write path (typed op, console text, bulk job, agent) is rejected and a protocol trace shows nothing sent.
- [ ] **AC2.** `EVAL_RO`/`FCALL_RO` are allowed on read-only; `EVAL` is blocked.
- [ ] **AC3.** Multi-key `DEL`, `FLUSHDB`, `FLUSHALL` require confirmation (UI) or approval (agent).
- [ ] **AC4.** Admin commands, `KEYS`, `MONITOR`, `SUBSCRIBE` and unknown commands are always blocked for agents.
- [ ] **AC5.** A blocked call returns its error without touching the socket.

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

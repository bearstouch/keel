# KEEL-046 · Approvals for destructive agent calls

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E6 Agents and MCP | P0 | 5 pts | S8 | [KEEL-044](KEEL-044-agent-tool-catalog-over-the-data-path.md), [KEEL-038](KEEL-038-typed-confirmations-and-multi-key-delete.md) |

**Specs:** [05 API → Approvals](../05-api.md#approvals), [FR-RC06](../03-functional-requirements.md#8-remote-control-mcp-server)

## Story

As a user, I want destructive agent requests to wait for my typed approval, so that no agent can delete data on its own.

## Scope

- `ApprovalCenter` actor: single-use approvals bound to grant, tool, params hash, connection revision and db; 5 min expiry
- `APPROVAL_REQUIRED` with `approvalId`; `approval_get`; retry with `approvalId`
- Approval card (non-modal) + notification: one sentence, typed confirmation, Deny / Allow once

## Acceptance criteria

- [ ] **AC1.** An agent `db_flush` returns `APPROVAL_REQUIRED` immediately; no modal blocks the app.
- [ ] **AC2.** After typing `db0` and Allow once, the agent's retry succeeds once; a second retry fails `APPROVAL_INVALID`.
- [ ] **AC3.** Changed parameters, expiry or denial → `APPROVAL_INVALID`.
- [ ] **AC4.** The card matches the `Agents` boards (manual design review).

## Unit tests

Test target: `KeelControlTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `ApprovalCenterTests.testSingleUse` | Single use |
| `ApprovalCenterTests.testBoundToParameters` | Bound to parameters |
| `ApprovalCenterTests.testExpiry` | injected clock |
| `ApprovalCenterTests.testDenial` | Denial |
| `ApprovalCardModelTests.testTypedConfirmationRequired` | Typed confirmation required |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

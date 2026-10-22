# KEEL-047 · Agents settings, activity and pause

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E6 Agents and MCP | P0 | 3 pts | S8 | [KEEL-045](KEEL-045-mcp-streamable-http-server.md), [KEEL-046](KEEL-046-approvals-for-destructive-agent-calls.md) |

**Specs:** [FR-RC05, FR-RC07, FR-RC08](../03-functional-requirements.md#8-remote-control-mcp-server), [API-09](../05-api.md#requirements)

## Story

As a user, I want one place to allow agents, manage their access and see what they did, so that I stay in control.

## Scope

- Settings → Agents per design: Allow agents switch + address, Access list (summary + status), Add agent…, ⋯ details (capabilities, scope, expiry, revoke, interface/port)
- Copy setup command for Claude Code (`<TOKEN>` placeholder); token shown once at creation
- Activity log (memory only, no values); Pause agents → `AGENTS_PAUSED`

## Acceptance criteria

- [ ] **AC1.** Revoking disconnects the agent at once.
- [ ] **AC2.** Activity never contains values and is empty after relaunch.
- [ ] **AC3.** Pause makes every call return `AGENTS_PAUSED` without revoking grants.
- [ ] **AC4.** The screen matches the `Agents` boards (manual design review).

## Unit tests

Test target: `KeelUITests, KeelControlTests`.

| Test | Verifies |
| --- | --- |
| `AgentsSettingsModelTests.testGrantSummaryText` | capabilities → plain language |
| `ActivityLogTests.testNoValuesRecorded` | No values recorded |
| `ActivityLogTests.testMemoryOnly` | Memory only |
| `PauseAgentsTests.testCallsRejectedWhilePaused` | Calls rejected while paused |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

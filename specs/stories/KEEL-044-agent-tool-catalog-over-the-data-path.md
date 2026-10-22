# KEEL-044 · Agent tool catalog over the data path

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E6 Agents and MCP | P0 | 8 pts | S7 | [KEEL-043](KEEL-043-grants-tokens-and-authorization-policy.md), [KEEL-013](KEEL-013-safety-policy-and-single-data-path.md) |

**Specs:** [05 API → Tool catalog](../05-api.md#tool-catalog), [05 API → Conventions](../05-api.md#conventions), [05 API → Errors](../05-api.md#errors)

## Story

As an agent developer, I want a documented set of tools for connections and data that behave exactly like the UI, so that agents are useful and safe.

## Scope

- `ControlHandler` implementing every tool in the catalog through `DataCommandService` with origin `.agent`
- Byte encoding (`utf8` / `base64`), cursors, limits (1 MiB, counts, maxBytes), idempotency keys (10 min, 1,000 per grant)
- Agent connections (role `agent`) opened lazily, closed after 5 min idle; `connection_create` defaults to read-only; untrusted-data notice item

## Acceptance criteria

- [ ] **AC1.** Every tool in 05 API exists with its schema; no other tools.
- [ ] **AC2.** Binary keys and values round-trip through `value_get` / `value_set`.
- [ ] **AC3.** `value_set` on a read-only profile returns `READ_ONLY` and sends nothing.
- [ ] **AC4.** Repeating a keyed call returns the original result; different params → `CONFLICT`.
- [ ] **AC5.** Responses over 1 MiB become `LIMIT_EXCEEDED`.
- [ ] **AC6.** Agents can't set, read or learn about secrets.

## Unit tests

Test target: `KeelControlTests`.

| Test | Verifies |
| --- | --- |
| `ToolCatalogTests.testCatalogMatchesSpec` | names and required params |
| `ByteEncodingTests.testUtf8AndBase64RoundTrip` | UTF-8 and base64 round trip |
| `ToolBehaviorTests.testReadOnlyEnforced` | Read only enforced |
| `ToolBehaviorTests.testBlockedCommandsForAgents` | Blocked commands for agents |
| `IdempotencyTests.testRepeatAndConflict` | Repeat and conflict |
| `LimitsTests.testOversizedResponse` | Oversized response |
| `ToolBehaviorTests.testConnectionCreateIsReadOnlyByDefault` | Connection create is read only by default |
| `ToolBehaviorTests.testNoSecretFieldsInResults` | No secret fields in results |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

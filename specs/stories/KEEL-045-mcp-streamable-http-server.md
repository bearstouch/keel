# KEEL-045 · MCP Streamable HTTP server

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E6 Agents and MCP | P0 | 5 pts | S8 | [KEEL-044](KEEL-044-agent-tool-catalog-over-the-data-path.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [05 API → Transport, Security controls](../05-api.md#transport), [FR-RC01–FR-RC04](../03-functional-requirements.md#8-remote-control-mcp-server), [NFR-SC06](../04-non-functional-requirements.md#security)

## Story

As a Claude Code user, I want to add Keel as an MCP server, so that my agent can work with my Redis connections.

## Scope

- `/mcp` POST/GET/DELETE semantics, protocol versions, sessions (`Mcp-Session-Id`, 30 min idle, 32 max)
- Bearer auth per request, session bound to token, auth rate limit 5/60 s
- Origin/Host checks, size/connection limits, idle timeouts, no CORS; off by default, loopback default, port 7778; non-loopback confirmation
- `initialize` instructions for agents

## Acceptance criteria

- [ ] **AC1.** A fresh install has no listener; `--no-mcp` and `--fixture` never listen.
- [ ] **AC2.** `claude mcp add --transport http keel http://127.0.0.1:7778/mcp --header "Authorization: Bearer kel_…"` lists the grant's tools.
- [ ] **AC3.** Non-loopback Origin → 403; missing token → 401 with `WWW-Authenticate`.
- [ ] **AC4.** Port in use shows "Port 7778 is already in use".

## Unit tests

Test target: `KeelMCPTests`.

| Test | Verifies |
| --- | --- |
| `MCPEndpointTests.testRequiresBearerOnEveryRequest` | Requires bearer on every request |
| `MCPEndpointTests.testSessionBoundToToken` | Session bound to token |
| `MCPEndpointTests.testOriginAndHostChecks` | Origin and host checks |
| `MCPEndpointTests.testBatchesRejected` | Batches rejected |
| `MCPListenerTests.testLimitsAndIdleTimeout` | Limits and idle timeout |
| `MCPListenerTests.testDefaultOffAndLoopback` | Default off and loopback |
| `MCPToolsTests.testToolsListFiltersByGrant` | Tools list filters by grant |

## Integration and manual checks

- Claude Code connected to a dev build; scope, read-only and revocation verified by hand.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

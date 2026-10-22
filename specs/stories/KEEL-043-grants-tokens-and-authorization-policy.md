# KEEL-043 · Grants, tokens and authorization policy

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E6 Agents and MCP | P0 | 5 pts | S7 | [KEEL-003](KEEL-003-owner-only-versioned-persistence.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [05 API → Grants and authorization](../05-api.md#grants-and-authorization)

## Story

As a user, I want to give each agent a limited, expiring grant, so that agents can only do what I allowed on the connections I chose.

## Scope

- `kel_` tokens (32 random bytes), Keychain `Keel Automation`, `grants.json` with SHA-256 hashes (constant-time compare)
- Capabilities, connection scope with connection-revision binding, expiry 60 s–90 days, revocation
- `AuthorizationPolicy` table for every tool

## Acceptance criteria

- [ ] **AC1.** The token is shown once and never stored in files.
- [ ] **AC2.** An out-of-scope profile ID returns `NOT_FOUND`.
- [ ] **AC3.** Changing a profile's host requires re-approval for scoped grants (`PERMISSION_DENIED`).
- [ ] **AC4.** Revocation takes effect on the next call and ends sessions.
- [ ] **AC5.** An unreadable `grants.json` makes the store read-only with no active grants.

## Unit tests

Test target: `KeelControlTests`.

| Test | Verifies |
| --- | --- |
| `GrantStoreTests.testTokenFormatAndHashOnly` | Token format and hash only |
| `GrantStoreTests.testConstantTimeCompare` | Constant time compare |
| `AuthorizationPolicyTests.testEveryToolHasPolicyEntry` | Every tool has policy entry |
| `AuthorizationPolicyTests.testOutOfScopeIsNotFound` | Out of scope is not found |
| `AuthorizationPolicyTests.testRevisionChangeNeedsReapproval` | Revision change needs reapproval |
| `GrantStoreTests.testUnreadableFileIsReadOnly` | Unreadable file is read only |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

# KEEL-006 · Handshake, authentication and error categories

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 5 pts | S2 | [KEEL-005](KEEL-005-redisconnection-actor-over-network-framework.md) |

**Specs:** [FR-CN10 error categories](../03-functional-requirements.md#connection-error-categories-fr-cn10), [INT-03](../06-integrations.md#protocol)

## Story

As a user, I want Keel to authenticate and select my database correctly and tell me exactly why a connection failed, so that I can fix it without guessing.

## Scope

- Handshake: `HELLO 3 AUTH user pass SETNAME keel` when supported, else `AUTH` (1 or 2 args) + `CLIENT SETNAME`, then `SELECT db`
- Map failures to `DNS_FAILED`, `CONNECTION_REFUSED`, `TIMEOUT` (with phase), `AUTH_FAILED`, `PERMISSION_DENIED`, `PROTOCOL_ERROR`, `DB_OUT_OF_RANGE`
- `CLIENT SETNAME` toggle per profile

## Acceptance criteria

- [ ] **AC1.** Wrong password → `AUTH_FAILED` naming the username, never the password.
- [ ] **AC2.** No password on a protected server → `AUTH_FAILED` saying a password is required (`NOAUTH`).
- [ ] **AC3.** Connecting to a non-Redis port (e.g. HTTP) → `PROTOCOL_ERROR` "This port doesn't look like a Redis server".
- [ ] **AC4.** `SELECT 20` on a 16-db server → `DB_OUT_OF_RANGE` with the db count.
- [ ] **AC5.** With SETNAME off, no `CLIENT SETNAME` is sent.

## Unit tests

Test target: `KeelRESPTests, KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `HandshakeTests.testUsesHelloWhenAvailable` | command sequence on Redis 7 fake |
| `HandshakeTests.testFallsBackToAuthWhenHelloUnknown` | `-ERR unknown command 'HELLO'` path |
| `HandshakeTests.testSetNameCanBeDisabled` | profile flag |
| `ConnectionErrorMappingTests.testMapsServerErrorsToCategories` | WRONGPASS, NOAUTH, NOPERM, ERR DB index |
| `ConnectionErrorMappingTests.testMessagesNeverContainPassword` | sanitization |

## Integration and manual checks

- ACL fixture user with `-select` gets `PERMISSION_DENIED` naming `SELECT`.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

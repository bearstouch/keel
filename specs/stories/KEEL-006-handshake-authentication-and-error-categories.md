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

- [x] **AC1.** Wrong password → `AUTH_FAILED` naming the username, never the password. *(Observed: `ConnectionErrorMappingTests.testMapsServerErrorsToCategories`, `testMessagesNeverContainPassword` (server text echoing the password, a username containing it); `HandshakeIntegrationTests.testWrongPasswordIsAuthFailed` against local Redis 7.2.1.)*
- [x] **AC2.** No password on a protected server → `AUTH_FAILED` saying a password is required (`NOAUTH`). *(Observed: `HandshakeTests.testNoPasswordOnProtectedServer`, `HandshakeReviewTests.testEmptyPasswordSendsNoAuth`, mapping in `testMapsServerErrorsToCategories`.)*
- [x] **AC3.** Connecting to a non-Redis port (e.g. HTTP) → `PROTOCOL_ERROR` "This port doesn't look like a Redis server". *(Observed with fakes: `HandshakeTests.testHttpPortIsProtocolError`, `HandshakeReviewTests.testBannerBeforeHelloIsReportedAsCodecError`, `ConnectionErrorMappingTests.testMapsHandshakeTransportFailures`. Not yet observed against a real HTTP port.)*
- [x] **AC4.** `SELECT 20` on a 16-db server → `DB_OUT_OF_RANGE` with the db count. *(Observed: `HandshakeTests.testDatabaseOutOfRangeReportsCount` and `HandshakeIntegrationTests.testSelectOutOfRangeNamesDatabaseCount` against local Redis 7.2.1.)*
- [x] **AC5.** With SETNAME off, no `CLIENT SETNAME` is sent. *(Observed: `HandshakeTests.testSetNameCanBeDisabled` on both HELLO and AUTH paths; `HandshakeIntegrationTests.testSetNameOffSendsNoName` (`CLIENT GETNAME` is nil).)*

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

- ACL fixture user with `-select` gets `PERMISSION_DENIED` naming `SELECT`. *(Observed against a disposable local `redis-server` 7.2.1, not the KEEL-053 container fixture: `KEEL_INTEGRATION=1 KEEL_INTEGRATION_REDIS_PORT=<port> swift test --filter HandshakeIntegrationTests` — the test creates and removes its ACL users. **Pending:** Redis 6.0/6.2, Valkey 7.2/8.x/9.x and Dragonfly matrix.)*

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

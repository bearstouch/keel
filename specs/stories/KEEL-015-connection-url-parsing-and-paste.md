# KEEL-015 · Connection URL parsing and paste

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 2 pts | S3 | [KEEL-014](KEEL-014-connection-profiles-and-keychain-secrets.md) |

**Specs:** [FR-CN08](../03-functional-requirements.md#1-connections), [INT-04](../06-integrations.md#connection-urls)

## Story

As a user, I want to paste a `redis://` or `rediss://` URL to fill the form, so that setting up a connection takes seconds.

## Scope

- `RedisURL` parser: scheme, user, password, host (incl. `[IPv6]`), port, db, percent-decoding, ignored query parameters
- Copy profile as URL without password

## Acceptance criteria

- [ ] **AC1.** `rediss://app:p%40ss@cache.internal:6380/2` fills TLS on, user `app`, password `p@ss`, host, port 6380, db 2.
- [ ] **AC2.** Unknown query parameters are listed as ignored.
- [ ] **AC3.** The URL is never persisted; the password goes to the Keychain on save.
- [ ] **AC4.** Malformed URLs show an inline error and change nothing.

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `RedisURLTests.testParsesFullURL` | Parses full URL |
| `RedisURLTests.testParsesIPv6Host` | Parses IPv6 host |
| `RedisURLTests.testPasswordOnlyUserinfo` | `:pass@` |
| `RedisURLTests.testReportsIgnoredQueryParameters` | Reports ignored query parameters |
| `RedisURLTests.testRejectsMalformedURLs` | table |
| `RedisURLTests.testCopyAsURLOmitsPassword` | Copy as urlomits password |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

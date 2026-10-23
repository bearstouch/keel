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

- [x] **AC1.** `rediss://app:p%40ss@cache.internal:6380/2` fills TLS on, user `app`, password `p@ss`, host, port 6380, db 2.
- [x] **AC2.** Unknown query parameters are listed as ignored.
- [x] **AC3.** The URL is never persisted; the password goes to the Keychain on save.
- [ ] **AC4.** Malformed URLs show an inline error and change nothing.

**Verification (KEEL-015).** Observed in `RedisURLTests` (`KeelCoreTests`).
- AC1: `testParsesFullURL` parses the URL and `applied(to:)` fills TLS, user, host, port and db (password returned as bytes).
- AC2: `testReportsIgnoredQueryParameters`: names are reported in order, de-duplicated, and never applied. Showing the
  list in the sheet arrives with KEEL-016.
- AC3: `testPastedURLIsNeverPersisted` saves a pasted URL through `ProfileStore`; the password is in the (fake)
  Keychain and `connections.json` contains neither it, the scheme nor the query.
- AC4 (**pending** an on-screen check): the KEEL-016 sheet shows `urlMessage` under the URL field and
  `ConnectionSheetModelTests.testPasteURLFillsFields` observes a refused URL changing no field; `testRejectsMalformedURLs` covers the table, a failed parse leaves the form
  unchanged and every `RedisURLError` has an inline `message`; the inline error display itself is not built yet.

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

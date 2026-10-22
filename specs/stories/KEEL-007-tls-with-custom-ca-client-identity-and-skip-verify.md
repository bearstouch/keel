# KEEL-007 · TLS with custom CA, client identity and skip-verify

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 8 pts | S2 | [KEEL-005](KEEL-005-redisconnection-actor-over-network-framework.md) |

**Specs:** [FR-CN03](../03-functional-requirements.md#1-connections), [INT-05](../06-integrations.md#tls-and-certificates), [NFR-SC02](../04-non-functional-requirements.md#security)

## Story

As an operator, I want to connect over TLS with my own CA and client certificate, so that I can reach secured and managed Redis servers.

## Scope

- `TLSConfiguration` → `sec_protocol_options`: min TLS 1.2, SNI override, anchor-only custom CA (PEM bundle), Keychain client identity by persistent reference, skip-verify
- PEM/PKCS#8 + certificate and `.p12` import into the login Keychain (`Keel TLS`), passphrase saved in Keychain
- Errors `TLS_UNTRUSTED`, `TLS_HOSTNAME_MISMATCH`, `TLS_HANDSHAKE_FAILED`, `NOT_TLS_EXPECTED`

## Acceptance criteria

- [x] **AC1.** A server signed by a private CA connects only when that CA is selected; otherwise `TLS_UNTRUSTED` names the issuer. *(Observed: `TLSIntegrationTests.testPrivateCAConnectsOnlyWhenSelected` against local Redis 7.2.1 with TLS ("Keel Fixture CA" named); `TLSConfigurationTests.testAnchorOnlyTrustRejectsSystemRoots` with fixture chains, including a public chain refused once a custom CA is selected.)*
- [x] **AC2.** A certificate for another name fails with `TLS_HOSTNAME_MISMATCH` listing expected and actual names; setting SNI fixes it. *(Observed: `TLSIntegrationTests.testHostnameMismatchIsFixedBySNI` — 127.0.0.1 vs “redis.keel.test”, fixed by server name `redis.keel.test`; `TLSConfigurationTests.testHostnameMismatchListsCertificateNames`.)*
- [x] **AC3.** A client-cert-required server rejects a profile without an identity and accepts it with one. *(Observed: `TLSIntegrationTests.testClientCertificateRequired` (`tls-auth-clients yes`; TLS 1.3 refusal at HELLO → `TLS_HANDSHAKE_FAILED` "requires a client certificate"); the identity there is decoded in memory. Keychain-imported identities observed only in a throwaway keychain (`SystemTLSIdentityKeychainTests`), not the login keychain.)*
- [x] **AC4.** Skip verification connects to a self-signed server and the connection reports `tlsVerified = false`. *(Observed: `TLSIntegrationTests.testSkipVerificationConnectsToSelfSigned`; `TLSConfigurationTests.testSkipVerificationAcceptsAnyChain`.)*
- [x] **AC5.** Connecting with TLS to a plain server reports "Server may not be using TLS". *(Observed: `TLSIntegrationTests.testTLSToPlainServerSaysSo` against plain Redis 7.2.1 — the TLS connect times out, the plain `PING` probe gets `+PONG`; `TLSConnectionReviewTests` with fakes.)*

## Unit tests

Test target: `KeelRESPTests, KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `TLSConfigurationTests.testAnchorOnlyTrustRejectsSystemRoots` | verify block with fixture chains |
| `TLSConfigurationTests.testSkipVerificationAcceptsAnyChain` | flag honored and surfaced |
| `TLSConfigurationTests.testMinimumVersionIsTLS12` | options built |
| `IdentityImporterTests.testImportsP12AndPEMPairs` | fixture files, injected Keychain |
| `IdentityImporterTests.testWrongPassphraseFailsWithoutPartialImport` | atomic import |
| `TLSErrorMappingTests.testMapsTrustResultsToCategories` | untrusted, mismatch, handshake |

## Integration and manual checks

- Redis TLS fixture with private CA, client-auth required, and a self-signed variant. *(Observed with disposable local `redis-server` 7.2.1 instances started by `Tests/Fixtures/TLS/serve.sh`, not the KEEL-053 container fixture: `KEEL_INTEGRATION=1 KEEL_INTEGRATION_REDIS_PORT=<plain port> swift test --filter TLSIntegrationTests`. **Pending:** Redis 6.0/6.2, Valkey 7.2/8.x/9.x and Dragonfly TLS matrix (KEEL-053); TLS 1.2-only servers (client-certificate refusal during the handshake); import into the real login keychain on macOS 14 and 15+, including the private-key access prompt, on a clean Mac.)*

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

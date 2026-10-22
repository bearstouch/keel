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

- [ ] **AC1.** A server signed by a private CA connects only when that CA is selected; otherwise `TLS_UNTRUSTED` names the issuer.
- [ ] **AC2.** A certificate for another name fails with `TLS_HOSTNAME_MISMATCH` listing expected and actual names; setting SNI fixes it.
- [ ] **AC3.** A client-cert-required server rejects a profile without an identity and accepts it with one.
- [ ] **AC4.** Skip verification connects to a self-signed server and the connection reports `tlsVerified = false`.
- [ ] **AC5.** Connecting with TLS to a plain server reports "Server may not be using TLS".

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

- Redis TLS fixture with private CA, client-auth required, and a self-signed variant.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

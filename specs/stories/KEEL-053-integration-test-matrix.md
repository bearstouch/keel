# KEEL-053 · Integration test matrix

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E7 App quality and release | P0 | 5 pts | S9 | [KEEL-011](KEEL-011-server-detection-capability-probes-and-minimum-version.md), [KEEL-009](KEEL-009-ssh-tunnel-manager.md), [KEEL-007](KEEL-007-tls-with-custom-ca-client-identity-and-skip-verify.md) |

**Specs:** [NFR-QA03](../04-non-functional-requirements.md#quality-and-maintainability), [INT-01](../06-integrations.md#redis-compatible-servers)

## Story

As the team, I want every supported server tested in CI, so that compatibility claims are backed by evidence.

## Scope

- `KeelIntegrationTests` with pinned container digests: Redis 6.0, 6.2, 7.4, 8.x, Valkey 7.2, 8.x, 9.x, Dragonfly 1.x; TLS (custom CA, client cert), ACL restricted users, sshd tunnel
- Opt-in locally via env flag; required in CI

## Acceptance criteria

- [ ] **AC1.** The matrix runs in CI and covers connect, detection, browse, each editor, console and bulk delete.
- [ ] **AC2.** A Redis 5 container is refused with `UNSUPPORTED_SERVER`.
- [ ] **AC3.** Tests never touch hosts outside the containers.

## Unit tests

Test target: `KeelIntegrationTests`.

| Test | Verifies |
| --- | --- |
| `ServerMatrixTests.testConnectDetectBrowsePerServer` | Connect detect browse per server |
| `ServerMatrixTests.testEditorsPerServer` | Editors per server |
| `TLSMatrixTests.testCustomCAAndClientCert` | Custom caand client cert |
| `TunnelMatrixTests.testBrowseThroughSSH` | Browse through SSH |
| `ServerMatrixTests.testRedis5Refused` | Redis5 refused |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

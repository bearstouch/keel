# KEEL-048 · Integration test matrix

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
- [x] **AC3.** Tests never touch hosts outside the containers.

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

## Verification (2026-10-24)

Docker Desktop's engine didn't start on the development Mac, and GitHub Actions started no jobs on this or the
previous commits (an account billing block), so **the container matrix has not run yet**.

- **AC1:** **pending.** `scripts/integration-matrix.py` and the CI `integration` job (`macos-15-intel` with Colima)
  are in place, but neither has been observed. What was observed: with `KEEL_INTEGRATION=1`, `ServerMatrixTests`
  (connect and detection, browse, each editor, console, bulk delete, restricted ACL user), `TLSMatrixTests` and
  `TunnelMatrixTests` pass against a native Homebrew `redis-server` 7.2.1 with `Tests/Fixtures/TLS/serve.sh` and
  `Tests/Fixtures/SSH/serve.sh`. The existing KEEL-005…010 integration tests also pass there. Redis 6.0/6.2/7.4/8.x,
  Valkey and Dragonfly have not been exercised: the review checked Dragonfly's ACL and error replies against its
  v1.40.2 source, but that was reading code, not a run. It also wasn't verified that Colima runs on
  `macos-15-intel` and that Xcode 26 is on that image.
- **AC2:** **pending.** `testRedis5Refused` and the pinned `redis:5.0.14` container exist, but they haven't run.
  The detection refusal itself is covered by the KEEL-011 unit tests.
- **AC3:** observed. The tests get ports only and always connect to `127.0.0.1` (`IntegrationMatrix.host`), and
  `IntegrationMatrixEnvironmentTests` pass. The script publishes every container port on `127.0.0.1` only.

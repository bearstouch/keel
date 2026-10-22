# KEEL-011 · Server detection, capability probes and minimum version

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 3 pts | S2 | [KEEL-006](KEEL-006-handshake-authentication-and-error-categories.md) |

**Specs:** [FR-CN11, FR-CN12](../03-functional-requirements.md#1-connections), [INT-01, INT-02](../06-integrations.md#redis-compatible-servers)

## Story

As a user, I want Keel to recognise Redis, Valkey and Dragonfly and adapt to what the server supports, so that features work or say "unavailable" instead of failing.

## Scope

- Data-driven rules in `Resources/ServerDetection.json` (Dragonfly → Valkey → Redis → unrecognized)
- Mode from `redis_mode` and `role`; cluster banner flag
- Probes: `MEMORY USAGE`, `OBJECT ENCODING`, `COMMAND DOCS`, `ZRANGE BYSCORE`, exclusive `XRANGE`, `PEXPIRETIME`, `EVAL_RO`
- Redis below 6.0 → `UNSUPPORTED_SERVER`

## Acceptance criteria

- [ ] **AC1.** Fixtures for Redis 6.0/7.4/8.x, Valkey 8 and Dragonfly are identified with the right version.
- [ ] **AC2.** Redis 5.0.7 is refused with "Keel requires Redis 6.0 or later; this server is Redis 5.0.7".
- [ ] **AC3.** A cluster node sets the cluster banner flag.
- [ ] **AC4.** Each probe result is cached per session and drives editor fallbacks (e.g. `ZRANGEBYSCORE` on 6.0).

## Unit tests

Test target: `KeelCoreTests`.

| Test | Verifies |
| --- | --- |
| `ServerDetectionTests.testIdentifiesFixtures` | INFO text fixtures per server |
| `ServerDetectionTests.testUnknownServerIsRedisCompatible` | Unknown server is redis compatible |
| `ServerDetectionTests.testRefusesBelowRedis6` | Refuses below redis6 |
| `CapabilityProbeTests.testProbesAreCachedPerSession` | Probes are cached per session |
| `CapabilityProbeTests.testUnsupportedCommandMarksFeatureUnavailable` | Unsupported command marks feature unavailable |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

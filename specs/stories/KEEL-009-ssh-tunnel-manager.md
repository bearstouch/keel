# KEEL-009 · SSH tunnel manager

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 8 pts | S3 | [KEEL-005](KEEL-005-redisconnection-actor-over-network-framework.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [FR-CN05](../03-functional-requirements.md#1-connections), [02 Architecture → SSH tunnels](../02-architecture.md#ssh-tunnels), [INT-06](../06-integrations.md#ssh-tunnels)

## Story

As an operator, I want to reach Redis behind a bastion through my normal OpenSSH setup, so that I don't need a separate tunnel or a second SSH implementation.

## Scope

- `TunnelManager` actor launching `/usr/bin/ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StreamLocalBindUnlink=yes -L <sock>:<host>:<port> …` from an argument array
- Unix-socket forward in an owner-only runtime dir; readiness = socket accepts within the connect timeout
- Reference counting per profile; close 10 s after last user; process-group termination; never signal a reused PID; cleanup of stale tunnels on next launch

## Acceptance criteria

- [ ] **AC1.** A profile via bastion reaches the bastion's local Redis and browsing works.
- [ ] **AC2.** The argument array never contains trust-bypass options; destinations starting with `-` are rejected.
- [ ] **AC3.** Closing the last tab terminates ssh within 11 s; quitting leaves no `ssh -N` child.
- [ ] **AC4.** A forward failure reports `TUNNEL_FAILED` with ssh's exit status and a sanitized last stderr line.
- [ ] **AC5.** No local TCP port is opened for the tunnel.

## Unit tests

Test target: `KeelSSHTests`.

| Test | Verifies |
| --- | --- |
| `SSHTunnelArgumentsTests.testBuildsArgumentArrayWithoutShell` | exact argv |
| `SSHTunnelArgumentsTests.testRejectsOptionInjectionDestinations` | `-oProxyCommand=…` |
| `TunnelManagerTests.testRefCountClosesAfterGracePeriod` | injected clock and process |
| `TunnelManagerTests.testNeverSignalsReusedPID` | OwnedProcessIdentity check |
| `TunnelManagerTests.testReportsForwardFailure` | fake ssh exit 255 |
| `RuntimeDirectoryTests.testOwnerOnlyAndSymlinkSafe` | 0700, no symlinks |

## Integration and manual checks

- sshd container + Redis behind it; host-key prompt path covered with KEEL-010.

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

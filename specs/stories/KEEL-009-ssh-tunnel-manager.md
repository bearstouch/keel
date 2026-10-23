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

- [ ] **AC1.** A profile via bastion reaches the bastion's local Redis and browsing works. *(Core observed: `TunnelIntegrationTests.testReachesRedisBehindBastionThroughUnixSocket` against the local unprivileged sshd fixture (`Tests/Fixtures/SSH/serve.sh`) — Redis bound to the bastion's loopback answers PING, SET and SCAN through the tunnel socket. **Pending:** a saved profile and the browser UI (ServerSession, key browser stories) and the KEEL-053 sshd container.)*
- [x] **AC2.** The argument array never contains trust-bypass options; destinations starting with `-` are rejected. *(Observed: `SSHTunnelArgumentsTests` — exact argv, `--` before the destination, `-oProxyCommand=…` and other injections rejected in every field, no forbidden option emitted; `TunnelManagerTests.testInvalidDestinationLaunchesNothing`.)*
- [ ] **AC3.** Closing the last tab terminates ssh within 11 s; quitting leaves no `ssh -N` child. *(Core observed: `TunnelIntegrationTests.testClosesAfterLastReleaseAndOnShutdown` — real ssh gone ≥ 9.5 s and ≤ 11 s after the last lease is released, and gone after `shutdown()`; the app calls `shutdown()` from `applicationShouldTerminate`. **Pending:** tabs holding leases (ServerSession / KEEL-026) and a `ps` check after quitting the app with an open tunnel.)*
- [x] **AC4.** A forward failure reports `TUNNEL_FAILED` with ssh's exit status and a sanitized last stderr line. *(Observed: `TunnelManagerTests.testReportsForwardFailure` (exit 255, escapes stripped), `SSHProcessLauncherTests.testReportsExitStatusAndSanitizedLastStderrLine` (real process), `TunnelErrorMappingTests`, and `TunnelIntegrationTests.testFailureReportsExitStatusAndStderr` (real ssh, 255, "Permission denied").)*
- [x] **AC5.** No local TCP port is opened for the tunnel. *(Observed: the forward is `-L <socket>:…` (`SSHTunnelArgumentsTests.testForwardIsAlwaysAUnixSocket`); `lsof -iTCP -sTCP:LISTEN` on the real ssh prints nothing in `TunnelIntegrationTests`.)*

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

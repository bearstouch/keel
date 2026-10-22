# KEEL-018 · SSH hosts library

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E2 Connection management | P0 | 3 pts | S3 | [KEEL-010](KEEL-010-askpass-broker-and-ssh-prompt-relay.md), [KEEL-002](KEEL-002-vendor-trellis-shared-code.md) |

**Specs:** [FR-CN06](../03-functional-requirements.md#1-connections), [INT-06](../06-integrations.md#ssh-tunnels)

## Story

As an operator, I want to pick an SSH host from my `~/.ssh/config` or Keel's saved hosts, with an optional Keychain password, so that tunnels are easy to configure.

## Scope

- Keel-owned `hosts.json` via vendored `HostLibrary`; `SSHConfigDiscovery` (literal aliases only, labeled unfollowed Includes)
- Host picker inside the SSH tunnel section; add/edit host; saved password with optional Touch ID before use

## Acceptance criteria

- [ ] **AC1.** Literal aliases from `~/.ssh/config` appear; wildcards and `Match` blocks don't; nothing is executed.
- [ ] **AC2.** A saved password is stored under `Keel SSH Host` and never shown again.
- [ ] **AC3.** With Touch ID required, declining falls back to the ssh prompt relay.

## Unit tests

Test target: `KeelSSHTests, KeelUITests`.

| Test | Verifies |
| --- | --- |
| `SSHConfigDiscoveryTests.testLiteralAliasesOnly` | ported |
| `SSHConfigDiscoveryTests.testUnfollowedIncludeIsLabeled` | ported |
| `HostPickerModelTests.testCombinesSavedAndDiscoveredHosts` | Combines saved and discovered hosts |
| `HostSecretsTests.testTouchIDDeclineFallsBack` | injected LAContext |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

# KEEL-010 · Askpass broker and SSH prompt relay

| Epic | Priority | Size | Sprint | Depends on |
| --- | --- | --- | --- | --- |
| E1 Protocol and connections | P0 | 5 pts | S3 | [KEEL-009](KEEL-009-ssh-tunnel-manager.md) |

**Specs:** [FR-CN06, FR-CN07](../03-functional-requirements.md#1-connections), [INT-06](../06-integrations.md#ssh-tunnels)

## Story

As a user, I want my saved SSH password used once and every other ssh question shown to me verbatim, so that tunnels work without a terminal and without Keel ever trusting a host key for me.

## Scope

- `keel-askpass` helper + broker (nonce, same-UID peer, helper executable check, parent = spawned ssh)
- Saved password answered once for `…password:` prompts only, bound to the host's connection revision
- `PromptRelay`: other prompts (host key, passphrase, OTP) forwarded to the app and shown in a sheet; the user's answer returned; timeout cancels

## Acceptance criteria

- [ ] **AC1.** A saved password is supplied at most once per tunnel; a second password prompt is shown to the user.
- [ ] **AC2.** An unknown host key shows ssh's exact text; Reject fails the connection with "Host key not accepted".
- [ ] **AC3.** A helper not launched by Keel's ssh, or with a reused nonce, gets no answer.
- [ ] **AC4.** Editing the host's destination removes its saved password (connection revision binding).

## Unit tests

Test target: `KeelSSHTests`.

| Test | Verifies |
| --- | --- |
| `AskpassBrokerTests.testAnswersPasswordOnce` | Answers password once |
| `AskpassBrokerTests.testRejectsForeignPeer` | parent/executable checks |
| `AskpassBrokerTests.testNonceIsSingleUse` | Nonce is single use |
| `PromptRelayTests.testNonPasswordPromptsReachUI` | classification of prompt text |
| `PromptRelayTests.testTimeoutCancelsPrompt` | Timeout cancels prompt |
| `HostSecretsTests.testDestinationChangeDeletesPassword` | Destination change deletes password |

## Definition of done

Meets the [shared definition of done](README.md#definition-of-done): format, lint, warning-free build, tests green, spec pages updated, independent review, acceptance boxes checked only when observed.

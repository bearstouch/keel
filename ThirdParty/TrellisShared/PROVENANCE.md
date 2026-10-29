# TrellisShared provenance

Source code copied from Trellis (Bearstouch) into Keel at build time ([Architecture → Reuse from Trellis](../../docs/architecture.md#reuse-from-trellis),
[INT-07](../../docs/integrations.md#trellis)). This is source reuse only: Keel never reads Trellis's state, settings
or Keychain items at run time and never calls the Trellis CLI.

| | |
| --- | --- |
| Upstream | Trellis repository, `master` |
| Commit | `6f826f66aabdae0b13f3d8319d07111f1c737a72` (2026-10-22, "docs(changelog): date 0.12.0 for the re-cut release") |
| Vendored by | KEEL-002 |
| License | Same owner (Bearstouch); no third-party license applies |

## How it builds

Each folder is named after the Keel target that compiles it, and `Sources/<Target>/TrellisShared` is a symlink to
`ThirdParty/TrellisShared/<Target>`, so SwiftPM builds the vendored files as part of that target. `swift format` does
not follow symlinks: format and lint `ThirdParty` explicitly (CLAUDE.md, CI).

## Files

| Keel file | Upstream file | Target |
| --- | --- | --- |
| `KeelAskpass/Askpass.swift` | `Sources/TrellisAskpass/Askpass.swift` | `KeelAskpass` |
| `KeelSSH/SavedHost.swift` | `Sources/TrellisCore/SavedHost.swift` | `KeelSSH` |
| `KeelSSH/HostLibrary.swift` | `Sources/TrellisCore/HostLibrary.swift` | `KeelSSH` |
| `KeelSSH/SSHConfigDiscovery.swift` | `Sources/TrellisCore/SSHConfigDiscovery.swift` | `KeelSSH` |
| `KeelSSH/HostSecrets.swift` | `Sources/TrellisCore/HostSecrets.swift` | `KeelSSH` |
| `KeelSSH/AskpassBroker.swift` | `Sources/TrellisCore/AskpassBroker.swift` | `KeelSSH` |
| `KeelCore/OwnerOnlyStorage.swift` | `Sources/TrellisCore/WorkspacePersistence.swift` (the `OwnerOnlyStorage` enum only) | `KeelCore` |
| `KeelCore/KeyboardShortcuts.swift` | `Sources/TrellisCore/KeyboardShortcuts.swift` | `KeelCore` |

Ported tests (in Keel's test targets, not here):

| Keel test | Upstream test |
| --- | --- |
| `Tests/KeelSSHTests/HostLibraryTests.swift` | `Tests/TrellisCoreTests/HostLibraryTests.swift` |
| `Tests/KeelSSHTests/HostLibraryReviewTests.swift` | `Tests/TrellisCoreTests/HostLibraryReviewTests.swift` |
| `Tests/KeelSSHTests/HostPasswordTests.swift` | `Tests/TrellisCoreTests/HostPasswordTests.swift` |
| `Tests/KeelSSHTests/SSHConfigDiscoveryTests.swift` | `Tests/TrellisCoreTests/SSHConfigDiscoveryTests.swift` (KEEL-018 renamed `testSkipPatternsAndMatch` → `testLiteralAliasesOnly` and `testIncludeHasExplicitLimitation` → `testUnfollowedIncludeIsLabeled`) |
| `Tests/KeelSSHTests/SSHConfigDiscoveryReviewTests.swift` | `Tests/TrellisCoreTests/SSHConfigDiscoveryReviewTests.swift` |
| `Tests/KeelSSHTests/AskpassTests.swift` | `Tests/TrellisCoreTests/AskpassTests.swift` |
| `Tests/KeelCoreTests/KeyboardShortcutTests.swift` | `Tests/TrellisCoreTests/KeyboardShortcutTests.swift` |

Keel-only tests over the vendored code: `HostLibraryCodecTests`, `VendoredIdentifiersTests` (KeelSSHTests)
and `OwnerOnlyStorageTests` (KeelCoreTests).

## Local changes

Where comments cited Trellis requirement IDs they now cite Keel's (INT-08, NFR-SC04, FR-AP02) or none, and
"session"/"pane" wording became "tunnel" where the code now serves SSH tunnels. Beyond that:

**`Askpass.swift`**
- Environment variables renamed to `SSH_ASKPASS_KEEL_SOCKET` / `SSH_ASKPASS_KEEL_NONCE` (still outside the app's own
  `KEEL_` prefix); helper name `keel-askpass`.
- KEEL-010 prompt relay: a request is now the header line `<nonce> <kind> <byte count>` plus ssh's prompt text
  (`AskpassProtocol.request(nonce:kind:prompt:)`, `header(from:)`, `promptLimit` 4 KiB) instead of the bare nonce
  line, and a new reply `D` (declined). The helper sends *every* prompt to the broker first (Trellis sent only password
  prompts) and falls back to the terminal only on `I` or without a broker; a confirm prompt's answer is its exit
  status. `AskpassPrompt` gained its one-letter wire code. The receive-timeout comment names the relayed prompt.

**`SavedHost.swift`**
- `connectionLaunch: SessionLaunch` (a Trellis terminal type) replaced by `sshArguments(options:) -> [String]`: the same
  `-p`, `-l`, `-i` arguments, then the caller's options (a tunnel's `-N` and forwards), then `--` and the destination.
  `sameConnection(as:)` compares those arguments.

**`HostLibrary.swift`**
- Comments (`hosts.json` lives in Keel's state folder).
- `setPassword(.save)`: a saved password that can't be read before it is replaced (Keychain locked or denied) aborts
  with `.secretStore` before anything is written; Trellis ignored the error, so a failed commit then left the new
  password in the Keychain under the old connection revision. The rollback of a failed commit now removes the new item
  whenever there was no previous value, including a saved one already missing from the Keychain.
  Tests: `HostPasswordTests.testUnreadablePreviousPasswordAbortsTheSave`,
  `testMetadataWriteFailureWithMissingItemLeavesNoPassword`.

**`SSHConfigDiscovery.swift`** — unchanged.

**`HostSecrets.swift`** — Keychain service `Keel SSH Host`, item label `Keel SSH host password`.
KEEL-018: `LocalAuthenticationGate` takes a `makeContext` closure (default `LAContext()`, a fresh one per request)
returning a `UserPresenceContext` — the one `evaluatePolicy(_:localizedReason:)` method `LAContext` already has — so
tests inject a context that declines. Behavior with the default is unchanged.

**`AskpassBroker.swift`** — imports `KeelAskpass`; socket folder prefix `keel-askpass-`; thread names `Keel askpass …`.
KEEL-010: `init(helperPath:relay:)` and `register(parent:destination:password:)` (was `answer:`). A nonce is no longer
consumed by its first request: it lives for one ssh launch, the saved password is handed out once
(`Entry.takePassword`), other prompts (and a second password prompt) go to the `PromptRelay`, and a failed peer check
revokes the nonce. Requests are read as header plus prompt; `unregister`/`stop` withdraw the launch's open prompts.
New `AskpassActivity` (prompt on screen, host key declined) on the registration, read by `TunnelManager`. The `wait`
comment no longer points at `MCPListener` (removed with the agent API).

**`OwnerOnlyStorage.swift`**
- Extracted from the workspace persistence file; the workspace codec and actor were not taken.
- Errors are a new `OwnerOnlyStorageError` (`corrupt`, `io`) instead of the workspace error type. Behavior unchanged.

**`KeyboardShortcuts.swift`**
- Trellis's terminal `ShortcutAction` enum and `ShortcutMenu` were removed. `ShortcutAction` is now a protocol
  (`title`, `defaultChord`, `laterDefaults`), and `ShortcutIssue`, `ShortcutMap` and the settings type are generic over
  it; Keel's action table is `Sources/KeelCore/KeelShortcuts.swift` (KEEL-043, a comment-only change here).
- `KeyboardSettings` became `ShortcutSettings<Action>` and dropped the terminal's Option-as-Meta flag (and its key in
  the saved JSON) and the matching reserved chord.
- Reserved chord names say "Quit Keel" / "Hide Keel"; the ⌘-required message names the console.

**Tests** — imports and fixture names use Keel names. Cases that drove Trellis's workspace
store (`testEditDoesNotMutateLiveLaunch`, the session part of `testDeleteDoesNotTouchSshFiles`) now assert the frozen
ssh arguments instead; shortcut tests use a stand-in action table.

## Not vendored yet

- Trellis's default terminal colors for the console — KEEL-041 (design tokens, not code).

The MCP HTTP layer (`HTTPMessage`, `MCPListener`, `IPAddressLiteral`, `MCPTransportSecurity` and their tests) was
vendored for KEEL-002 and removed on 2026-10-23 with the agent API.

## Keel code derived from Trellis

Not vendored (it lives in `Sources/`), but adapted from Trellis at the same commit:

- `Sources/KeelSSH/OwnedProcessIdentity.swift` (KEEL-009): `OwnedProcessIdentity` and its `permitsSignal` rule from
  `Sources/TrellisCore/SessionClosure.swift`; the identity is read with `proc_pidinfo` in Swift instead of Trellis's
  `trellis_read_process_identity` C helper. `OwnedProcessGroup` (signal and reap under one lock) is Keel's own.

Keel's own, built on the vendored askpass (KEEL-010): `Sources/KeelSSH/PromptRelay.swift`, `AskpassHelperLocation.swift`,
`HostLibrary+Tunnel.swift`, and `Sources/KeelUI/SSHPromptSheet.swift`. Ported tests updated for the new wire format:
`AskpassTests.testNonceFraming`, `testHelperFallsBackToTerminalForEverythingElse` (trust prompts now reach the broker
first) and the broker cases (`password:` label, revocation wording).

## Bundled fonts (KEEL-044)

Not code: font files in `Sources/KeelUI/Resources/Fonts/`, shipped with their SIL Open Font License 1.1 texts
(`Inter-OFL.txt`, `JetBrainsMono-OFL.txt`) and registered for the Keel process only (MAC-19).

| Files | Source | SHA-256 |
| --- | --- | --- |
| `Inter-Regular.ttf`, `Inter-Medium.ttf`, `Inter-SemiBold.ttf`, `Inter-OFL.txt` (`LICENSE.txt`) | Inter 4.1 release (`Inter-4.1.zip`, `extras/ttf/`), github.com/rsms/inter | `40d692fc…0c82`, `97ad806f…a872`, `78a843fa…cde3` |
| `JetBrainsMono-{Regular,Bold,Italic,BoldItalic}.ttf`, `JetBrainsMono-OFL.txt` | Trellis `Sources/TrellisCore/Resources/Fonts/` at `f76ba9823f6213698acee86349c597e95e46f25e` | `a0bf60ef…138f`, `5590990c…9dcb`, `9d0a1f7a…ded4`, `4039d5ce…aa3b` |

# TrellisShared provenance

Source code copied from Trellis (Bearstouch) into Keel at build time ([02 Architecture → Reuse from Trellis](../../specs/02-architecture.md#reuse-from-trellis),
[INT-07](../../specs/06-integrations.md#trellis)). This is source reuse only: Keel never reads Trellis's state, settings
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
| `KeelMCP/HTTPMessage.swift` | `Sources/TrellisMCP/HTTPMessage.swift` | `KeelMCP` |
| `KeelMCP/MCPListener.swift` | `Sources/TrellisMCP/MCPListener.swift` | `KeelMCP` |
| `KeelMCP/IPAddressLiteral.swift` | `Sources/TrellisCore/RemoteControlSettings.swift` (the `IPAddressLiteral` enum only) | `KeelMCP` |
| `KeelMCP/MCPTransportSecurity.swift` | `Sources/TrellisMCP/MCPEndpoint.swift` (static helpers only) | `KeelMCP` |

Ported tests (in Keel's test targets, not here):

| Keel test | Upstream test |
| --- | --- |
| `Tests/KeelSSHTests/HostLibraryTests.swift` | `Tests/TrellisCoreTests/HostLibraryTests.swift` |
| `Tests/KeelSSHTests/HostLibraryReviewTests.swift` | `Tests/TrellisCoreTests/HostLibraryReviewTests.swift` |
| `Tests/KeelSSHTests/HostPasswordTests.swift` | `Tests/TrellisCoreTests/HostPasswordTests.swift` |
| `Tests/KeelSSHTests/SSHConfigDiscoveryTests.swift` | `Tests/TrellisCoreTests/SSHConfigDiscoveryTests.swift` |
| `Tests/KeelSSHTests/SSHConfigDiscoveryReviewTests.swift` | `Tests/TrellisCoreTests/SSHConfigDiscoveryReviewTests.swift` |
| `Tests/KeelSSHTests/AskpassTests.swift` | `Tests/TrellisCoreTests/AskpassTests.swift` |
| `Tests/KeelMCPTests/HTTPRequestParserTests.swift` | `Tests/TrellisMCPTests/HTTPParserTests.swift` + the duplicate-Host case of `MCPReviewTests.swift` |
| `Tests/KeelMCPTests/MCPListenerTests.swift` | `Tests/TrellisMCPTests/MCPListenerTests.swift` |
| `Tests/KeelMCPTests/MCPTransportSecurityTests.swift` | `testHostAndOriginHelpers` of `MCPEndpointTests.swift`, loopback cases of `RemoteControlSettingsTests.swift` |
| `Tests/KeelCoreTests/KeyboardShortcutTests.swift` | `Tests/TrellisCoreTests/KeyboardShortcutTests.swift` |

Keel-only tests over the vendored code: `HostLibraryCodecTests`, `VendoredIdentifiersTests` (KeelSSHTests),
`OwnerOnlyStorageTests` (KeelCoreTests), and the bearer/hash cases of `MCPTransportSecurityTests`.

## Local changes

Where comments cited Trellis requirement IDs they now cite Keel's (INT-08, NFR-SC04, FR-RC0x, FR-AP02) or none, and
"session"/"pane" wording became "tunnel" where the code now serves SSH tunnels. Beyond that:

**`Askpass.swift`**
- Environment variables renamed to `SSH_ASKPASS_KEEL_SOCKET` / `SSH_ASKPASS_KEEL_NONCE` (still outside the app's own
  `KEEL_` prefix); helper name `keel-askpass`.
- Doc comment of `AskpassHelper`: without a terminal (Keel's tunnels) a typed prompt fails closed until the prompt
  relay (KEEL-010). Behavior unchanged.

**`SavedHost.swift`**
- `connectionLaunch: SessionLaunch` (a Trellis terminal type) replaced by `sshArguments(options:) -> [String]`: the same
  `-p`, `-l`, `-i` arguments, then the caller's options (a tunnel's `-N` and forwards), then `--` and the destination.
  `sameConnection(as:)` compares those arguments.

**`HostLibrary.swift`** — comments only (`hosts.json` lives in Keel's state folder).

**`SSHConfigDiscovery.swift`** — unchanged.

**`HostSecrets.swift`** — Keychain service `Keel SSH Host`, item label `Keel SSH host password`.

**`AskpassBroker.swift`** — imports `KeelAskpass`; socket folder prefix `keel-askpass-`; thread names `Keel askpass …`.

**`OwnerOnlyStorage.swift`**
- Extracted from the workspace persistence file; the workspace codec and actor were not taken.
- Errors are a new `OwnerOnlyStorageError` (`corrupt`, `io`) instead of the workspace error type. Behavior unchanged.

**`KeyboardShortcuts.swift`**
- Trellis's terminal `ShortcutAction` enum and `ShortcutMenu` were removed. `ShortcutAction` is now a protocol
  (`title`, `defaultChord`, `laterDefaults`), and `ShortcutIssue`, `ShortcutMap` and the settings type are generic over
  it; Keel's action table arrives with KEEL-048.
- `KeyboardSettings` became `ShortcutSettings<Action>` and dropped the terminal's Option-as-Meta flag (and its key in
  the saved JSON) and the matching reserved chord.
- Reserved chord names say "Quit Keel" / "Hide Keel"; the ⌘-required message names the console.

**`HTTPMessage.swift`** — unchanged.

**`MCPListener.swift`** — no longer imports the Trellis core module (`IPAddressLiteral` is vendored beside it); thread
names `Keel MCP …`; comments.

**`IPAddressLiteral.swift`** — extracted unchanged from the remote-control settings file.

**`MCPTransportSecurity.swift`** — the endpoint's static `bearer`, `hash`, `constantTimeEqual`, `isLoopbackHost` and
`isLoopbackOrigin`, made public on a new `MCPTransportSecurity` enum. Behavior unchanged.

**Tests** — imports and fixture names use Keel names; the MCP test port is 7778. Cases that drove Trellis's workspace
store (`testEditDoesNotMutateLiveLaunch`, the session part of `testDeleteDoesNotTouchSshFiles`) now assert the frozen
ssh arguments instead; shortcut tests use a stand-in action table; the end-to-end MCP server test waits for KEEL-045.

## Not vendored yet

These rows of the architecture table depend on Keel's own control layer, so the story that builds that layer copies
them and extends this file:

- The MCP endpoint's session and JSON-RPC handling, and the server wrapper (`MCPEndpoint.swift`, `MCPServer.swift`) —
  KEEL-045.
- The grant store and authorization pattern (`AutomationGrant.swift`, `Authorization.swift`), including the
  `Keel Automation` Keychain service — KEEL-043.
- Trellis's default terminal colors for the console — KEEL-041 (design tokens, not code).

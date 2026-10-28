# Project status

Keel v1 is feature-complete against its P0 scope and in release qualification. All five
[milestones](../overview.md#milestones) have been implemented. What remains are the manual and environment-dependent
checks below, which stay **pending** until someone observes them. `CHANGELOG.md` lists what each change delivered.

## Delivered

| Area | Delivered |
| --- | --- |
| Foundation | Package scaffold, CI, vendored Trellis code with provenance, owner-only versioned persistence |
| Protocol and connections | RESP2/RESP3 codec, `RedisConnection`, handshake and error categories, TLS (custom CA, client identity, skip-verify), CA change detection, SSH tunnels with askpass relay, server detection and capability probes, command catalog, safety policy and the single data path |
| Connection management | Profiles and Keychain secrets, URL paste, New Connection sheet and Test Connection, sidebar, SSH hosts library, profile import/export |
| Key browser | SCAN key index, namespace tree with binary-safe names, virtualized tree and flat lists, filters, row metadata, database switcher, windows, tabs and modes |
| Editors and safety | Editor shell with save bar and conflicts, value viewers, editors for string, hash, list, set, sorted set and stream, key actions, new-key sheet, read-only mode and production chrome, typed confirmations, multi-key and bulk delete |
| Console and Info | Console parser and redis-cli formatter, console view with history, completion, streaming and masking, INFO overview |
| App quality and release | Command palette and rebindable shortcuts, design tokens and bundled fonts, accessibility pass, privacy and logging guardrails, benchmarks, integration matrix, settings window, welcome screen and data removal, app icon assets, packaging, signing, notarization and Sparkle updates |

## Pending verification

These acceptance checks have not been observed yet. Automated parts are covered by tests; what is listed here still
needs a person, hardware or an environment that wasn't available.

### Manual design reviews (light and dark)

| Screen | Canvas boards |
| --- | --- |
| New Connection sheet | `Connection` / `ConnectionDark` |
| Sidebar | `Sidebar` |
| Key list, toolbar and tabs | `Main` |
| Value viewer | `Main` (both themes) |
| Console | `Console` / `ConsoleDark` |
| Info overview | `Info` / `InfoDark` |

### Accessibility and keyboard

- Full VoiceOver pass recorded by hand (NFR-AX); VoiceOver reading name, label and status for each sidebar row.
- The [cross-feature acceptance scenario](../overview.md#cross-feature-acceptance-scenario) completed keyboard-only in
  the launched app against real servers. Tab order, arrow navigation and focus moves are covered by
  `KeyboardNavigationTests`.
- New Connection sheet fully keyboard-operable, with every field labeled.

### Behavior in the running app

- Malformed connection URLs show an inline error and change nothing.
- Closing a tab with unsaved edits asks first.
- Switching between two connected tabs in Console mode, and moving one to another window, keeps keyboard focus in
  the selected tab's console and its typed-confirmation sheets bound to that tab (the view swap is tested in
  `TabContentIdentityReviewTests`).
- A key such as `\xff\x00a` displays escaped and can be opened, renamed and deleted.
- Capability probe results are cached per session and drive editor fallbacks (for example `ZRANGEBYSCORE` on 6.0).
- The CA-change prompt shows both fingerprints on screen (the core flow is tested in `KnownCATests`).
- A saved profile through an SSH bastion browses end to end; closing the last tab ends ssh within 11 s and quitting
  leaves no `ssh -N` child (checked with `ps`). The tunnel core is tested in `TunnelIntegrationTests`.
- With `ControlMaster auto` + `ControlPersist` and `ForkAfterAuthentication yes` under `Host *` in `~/.ssh/config`, a
  tunnel still runs as Keel's own foreground ssh and ends with its last tab; with a `LocalForward` for the bastion,
  connecting shows the `TUNNEL_FAILED` config-forwards message (the `ssh -G` check is tested against the real
  `/usr/bin/ssh` in `SSHTunnelArgumentsTests`, the refusal in `TunnelManagerTests`).
- Keel and Trellis run at the same time without sharing state.
- MAC-17: a second `swift run Keel` (or `open -n` of the built app) brings the running instance's windows forward and
  exits 75, while the installed and development builds still run side by side. The lock itself is tested in
  `InstanceLockTests`; the activation needs a logged-in session.
- The built app shows the icon in the Dock, Finder and ⌘-Tab, and dark and tinted appearances follow the system
  setting.

### Performance

- All [NFR-PF](../requirements/non-functional.md#performance) targets measured on Apple silicon and recorded in the
  release evidence. Intel is pending until hardware is available.
- 1M loaded keys scroll at display frame rate (hitch ratio under 5 ms/s, measured in Instruments).
- 1M keys of about 30 bytes use under 200 MB for the index and tree.
- A 1M-field hash shows its first page in under 1 s. Hex view of a 1 MiB value renders without blocking the UI.
- Browsing stays responsive during a bulk delete.

### Privacy

- A full scenario under `log stream --level debug` shows no key names, values or secrets. The logging wrapper and
  source scan are tested (`LoggingPolicyTests`, `SourceScanTests`).
- `nettop` during the acceptance scenario shows no traffic except configured servers, SSH and the update feed.

### Integration and release

- The container integration matrix running in CI and covering connect, detection, browse, each editor, console and
  bulk delete. A Redis 5 container is refused with `UNSUPPORTED_SERVER`. The matrix had not run yet at the last
  check: Docker was unavailable on the development Mac and CI jobs were blocked.
- Console goldens re-captured with redis-cli 7.4. The current goldens match redis-cli 7.2.1 byte for byte.
- `spctl --assess` accepts the notarized app on a clean Mac.
- An update from version N to N+1 installs after confirmation, and a tampered update is rejected by the EdDSA check.

## Known gaps

- **Large node expansion.** `NSOutlineView.expandItem` takes about 0.3 s for a node with 500,000 children (its own
  per-child bookkeeping; Keel's callbacks take about 40 ms), so FR-KB04's 200 ms expand check is not met yet.
- **Xcode 26.3 and later aren't used.** Test runs built by Xcode 26.3 (Swift 6.2.4) and 26.6 (Swift 6.3.3) abort on
  GitHub's `macos-26` runners with "freed pointer was not the last allocation" in a `Persistence` debounce task whose
  `Task.sleep` ends without suspending (a zero debounce, or a task cancelled before it sleeps). The same suite, with
  those tests, passes when built by Xcode 26.0.1 on the same runner, so CI and `release.yml` pin Xcode 26.0.1 until a
  later Xcode is shown not to miscompile this. Local runs with Xcode 27.1 (Swift 6.4) also pass.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Network.framework TLS with custom anchors and client identities | Blocks managed and secured servers | Fixture coverage; `SecTrust` evaluation in the verify block |
| ssh prompts without a terminal | Tunnels fail on the first host-key prompt | Askpass relay, tested with an sshd fixture |
| 1M-key smoothness in AppKit lists | The browser's core promise | Compact arena index, lazy display strings, benchmarks with a regression gate |
| Server variance (Dragonfly, managed services) | Features fail unexpectedly | Capability probes and "unavailable" states; integration matrix |
| Notarization and Sparkle setup | Release delay | Dry-run packaging with ad-hoc signing; pinned actions |

## Later versions

P1 and P2 features are listed in [Product overview → Scope](../overview.md#scope). Cluster and KeyDB support need
requirement updates before any code.

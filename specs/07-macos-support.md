# 07 macOS support

Keel is a macOS-only application.

## Supported platform

- **MAC-01 (P0):** macOS 14 Sonoma minimum, and every later public major version through the current stable release. Each release publishes the matrix actually tested. Beta OS releases are best effort.
- **MAC-02 (P0):** native Swift, built as Universal 2: arm64 and x86_64 slices built natively and combined with `lipo`. Running under Rosetta doesn't count as Intel qualification.
- **MAC-03 (P0):** SwiftUI for chrome and settings; AppKit for virtualized key lists, tables, the console text view and the responder chain. No Electron, webview or browser runtime.

## Native behavior

- **MAC-04 (P0):** integrates with the menu bar (menus built from current shortcut bindings), Settings (⌘,), the Dock, standard hide/minimize/full screen, the Window menu, standard open/save panels, system appearance, notifications (approvals, finished bulk jobs, only when the app is in the background), and Services where meaningful (copy key name).
- **MAC-05 (P0):** multiple native windows, each with Keel's own tab bar. macOS automatic window tabbing is disabled; every tab belongs to Keel's model. Window frames restore constrained to the available displays.
- **MAC-06 (P0):** closing a window with unsaved value edits asks once; closing a window with a running bulk job asks whether to cancel it. Quitting with running bulk jobs or connected agents offers **Cancel Jobs and Quit** / **Don't Quit**; there's no background continuation after quit.
- **MAC-07 (P0):** Retina and non-Retina, display changes, full screen, Stage Manager and Split View; small windows keep minimum sizes for the key list and editor and collapse the sidebar instead of overlapping.

## Distribution, signing and updates

- **MAC-08 (P0):** distributed directly as a signed DMG (not the Mac App Store), Developer ID signed with the hardened runtime, notarized and stapled. The app and the bundled `keel-askpass` helper (`Contents/Helpers`) are signed; Sparkle's helpers are signed as Sparkle documents. Automatic updates through Sparkle 2 (INT-11): EdDSA-signed appcast, user-confirmed install, daily check that can be turned off. Gatekeeper acceptance is verified on a clean machine (**pending** until observed).
- **MAC-09 (P0):** not sandboxed. Keel must run `/usr/bin/ssh`, read `~/.ssh/config`, and reference certificate files anywhere the user keeps them. Entitlements: none beyond the hardened runtime defaults (no JIT, no unsigned memory, no library validation exceptions). A sandboxed build would need its own feasibility decision.
- **MAC-10 (P0):** release decisions are recorded in `release/manifest.json` (version, bundle ID `com.bearstouch.keel`, minimum macOS, architectures, helpers, Sparkle feed URL and public EdDSA key) and checked by `KeelReleaseTests`. `scripts/package-release.sh` produces `dist/Keel.app`, `dist/Keel-<version>.dmg`, the Sparkle archive and `dist/release-evidence.json`; ad-hoc unless `KEEL_SIGN_IDENTITY` / `KEEL_NOTARY_PROFILE` are set. A signed-but-not-notarized build is only ever published as a pre-release.
- **MAC-11 (P0):** the release workflow pins actions to commit SHAs, verifies signature, hardened-runtime flag, both architectures, minimum OS and `spctl`, and publishes `SHA256SUMS.txt`.

## Files, credentials and permissions

- **MAC-12 (P0):** durable configuration in `~/Library/Application Support/com.bearstouch.keel/` (`.dev` for development builds, override with `--state-directory`); disposable data in Caches; tunnel and askpass sockets in an owner-only directory in the per-user `$TMPDIR`. Files `0600`, directories `0700`.
- **MAC-13 (P0):** secrets in the login Keychain (services in [Architecture](02-architecture.md#keychain-items)), *when unlocked, this device only*. Private-key contents are never written to files.
- **MAC-14 (P0):** **Local Network privacy** (macOS 15+): connecting to LAN servers triggers the system Local Network prompt; `Info.plist` includes `NSLocalNetworkUsageDescription` ("Keel connects to Redis servers on your local network that you configure."). A denied permission is detected and explained with a link to System Settings → Privacy & Security → Local Network, instead of a generic timeout.
- **MAC-15 (P0):** binding the MCP server to a non-loopback interface may trigger the application firewall prompt; Keel explains this in Settings → Agents. Loopback binds don't.
- **MAC-16 (P0):** no root helper, no launchd agent or login item, no kernel or system extensions. Keel never asks for Accessibility, Screen Recording, Full Disk Access or Input Monitoring. Notifications permission is requested only when the user first enables a notification-producing feature (approvals or job completion).
- **MAC-17 (P0):** one instance per user per identity; opening Keel again brings the existing instance forward. The installed app and development builds (`com.bearstouch.keel.dev`) are separate identities with separate state, locks and MCP settings, so both can run at once.

## Input and text

- **MAC-18 (P0):** native text input everywhere: IME composition, dead keys, emoji, right-to-left text in values; the console and editors use `NSTextView` so system text services work. All configurable shortcuts include ⌘ (⌃ alone is reserved for console editing keys such as ⌃R, ⌃L, ⌃A/⌃E).
- **MAC-19 (P0):** bundled fonts are registered for the Keel process only: Inter (Regular, Medium, SemiBold; OFL 1.1) for all interface text, and JetBrains Mono (Regular/Bold/Italic/Bold Italic) for keys, values and the console. If a bundled font fails to load, Keel falls back to the system font (or the system monospace font) with no loss of function.

## Installation, upgrades and removal

- **MAC-20 (P0):** install by dragging `Keel.app` from the DMG to Applications. No installer package, no writes to system directories, no shell startup file edits.
- **MAC-21 (P0):** upgrades through Sparkle or by replacing the app; persisted formats are versioned and migrated with backups; newer formats open read-only and are never overwritten. Downgrades aren't supported.
- **MAC-22 (P0):** uninstalling = deleting the app. Help → **Remove Keel Data…** lists and deletes the state directory and Keel's Keychain items (all four services), after a confirmation. It never touches SSH keys, SSH configuration, known-hosts files, Trellis data or Redis servers.

## Release verification matrix

| Area | Required evidence |
| --- | --- |
| OS and architecture | Cold launch and the acceptance scenario on macOS 14 and the current release, on Apple silicon and Intel |
| Servers | Integration matrix (INT-01) green, plus a manual run against one managed TLS service |
| Connections | TLS custom CA, client cert, skip-verify banner, SSH tunnel with known/unknown/changed host key, password and agent auth, Local Network prompt |
| Browser | 1M-key performance targets (NFR-PF02–PF05) with recorded evidence |
| Safety | Read-only protocol trace, typed confirmations, bulk delete cancel, production chrome |
| Agents | Claude Code connected via MCP; scope, read-only, approvals, revocation |
| Accessibility | VoiceOver pass, keyboard-only pass, Increase Contrast, Reduce Motion |
| Security | Gatekeeper, signing, notarization, Sparkle EdDSA verification, no secrets in files or logs, no unexpected network traffic |
| Lifecycle | Quit with jobs, crash recovery, restore of windows and tabs, data removal |

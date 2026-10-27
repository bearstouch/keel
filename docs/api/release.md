# KeelRelease and KeelApp

`KeelRelease` holds the pure release checks: the release manifest and built-product validation, release evidence,
the Sparkle update policy and the Remove Keel Data plan. It has no UI and performs no network I/O; Keychain and
defaults access go through injected seams. `KeelApp` is the executable: `@main`, launch arguments, `AppDelegate`,
menus built from shortcut bindings and Sparkle wiring. It wires modules together and must never contain domain logic,
start an updater in development or `--fixture` builds, or touch Trellis state.

Behavior: [Updates](../integrations.md#updates), [macOS](../macos.md), [Errors](../architecture.md#errors).

## Release manifest

### `ReleaseManifest` (struct, Codable, Sendable)

Decoded from `release/manifest.json`; the source of truth that `scripts/package-release.sh` and the tests check against.

```swift
public let bundleIdentifier: String, name: String, version: String, minimumMacOS: String
public let architectures: [String], packageFormat: String, iconName: String
public let artifacts: [String], dependencies: [Dependency], sparkle: Sparkle, releaseChecks: [String]

public struct Dependency: Codable { public let name, version, revision, license, licenseFile: String }
public struct Sparkle: Codable { public let version, feedURL, downloadURLPrefix, publicEDKey: String }
public struct BuiltProduct: Equatable, Sendable {
    public var bundleIdentifier: String, minimumMacOS: String
    public var architectures: Set<String>, files: Set<String>, iconName: String?
}

public static func packageMinimumMacOS(in packageSource: String) -> String?   // reads Package.swift
public func problems(packageMinimumMacOS: String, product: BuiltProduct) -> [String]
public var sparkleProblems: [String] { get }
```

`problems` returns human-readable mismatches (empty means pass): identifier, minimum macOS vs `Package.swift`,
Universal 2 architectures, required files (helpers included), icon.

### `ReleaseEvidence` (struct, Codable, Sendable) and `ReleaseChecklist`

Written to `dist/release-evidence.json` by the packaging script.

```swift
public enum Status: String, Codable { case passed, failed, skipped }
public enum Channel: String, Codable { case release, prerelease }
public struct Check: Codable, Equatable, Sendable { public var id: String, status: Status, detail: String }
public var version: String, channel: Channel, checks: [Check], artifacts: [String: String]

public enum ReleaseChecklist {
    public static func channel(for checks: [ReleaseEvidence.Check]) -> ReleaseEvidence.Channel
    public static func problems(_ evidence: ReleaseEvidence, manifest: ReleaseManifest) -> [String]
}
```

A skipped check (ad-hoc signing, no notarization) makes the build `prerelease`; `problems` flags manifest
`releaseChecks` that are missing or failed.

## Update policy

### `UpdatePolicy` (enum namespace)

Sparkle 2 over HTTPS with an EdDSA-signed appcast, a daily check the user can turn off, installs only after
confirmation, never a system profile.

```swift
public static let checkInterval: TimeInterval            // 86_400
public static let requiredInfoValues: [String: Bool]      // SUEnableSystemProfiling=false, SUAllowsAutomaticUpdates=false,
                                                          // SUAutomaticallyUpdate=false, SUEnableAutomaticChecks=true,
                                                          // SURequireSignedFeed=true, SUVerifyUpdateBeforeExtraction=true
public static let forbiddenInfoKeys: [String]             // SUSendProfileInfo, SUCustomFeedParameters
public static let sparklePreferenceKeys: [String]         // removed by Remove Keel Data
public static func isAvailable(info: [String: Any]?, productionBundleIdentifier: String) -> Bool
public static func isPublicEDKey(_ text: String) -> Bool  // base64 of 32 bytes
public static func problems(info: [String: Any], sparkle: ReleaseManifest.Sparkle) -> [String]
@MainActor public static func apply(checksAutomatically: Bool, to updater: some UpdaterControlling)
```

`isAvailable` is true only for the installed bundle id with an HTTPS feed and a valid public key, so `swift run` and
development builds never start an updater or contact the network.

### `UpdaterControlling` (protocol, @MainActor, AnyObject)

```swift
var automaticallyChecksForUpdates: Bool { get set }
var automaticallyDownloadsUpdates: Bool { get set }
var sendsSystemProfile: Bool { get set }
var updateCheckInterval: TimeInterval { get set }
```

`KeelApp` conforms Sparkle's `SPUUpdater` with an empty extension.

## Data removal

Help > Remove Keel Data... First a read-only plan, shown to the user, then execution.

```swift
public enum DataRemovalPlanner {
    public static let keychainServices = ["Keel Connection", "Keel TLS", "Keel SSH Host"]
    public static let preferenceKeys: [String]     // "keyboardShortcuts" + UpdatePolicy.sparklePreferenceKeys
    public static let stateFileStems = ["connections", "hosts", "windows", "settings", "known-ca"]
    public static func isKeelFile(_ name: String) -> Bool
    public static func protectedReason(_ directory: URL, home: URL) -> String?
    public static func plan(stateDirectory: URL, home: URL, keychain: any KeychainInventory,
                            storedPreferenceKeys: Set<String>, fileManager: FileManager = .default) -> DataRemovalPlan
    public static func execute(_ plan: DataRemovalPlan, keychain: any KeychainInventory,
                               removePreference: (String) -> Void) -> DataRemovalResult
}
```

| Type | Kind | Purpose |
| --- | --- | --- |
| `DataRemovalPlan` | struct, Sendable | `files`, `keptEntries` (unknown entries are never deleted), `keychainItems`, `preferenceKeys`, `refusal` (symlinked or protected folder), `unreadableServices`; `removesDirectory`, `isEmpty`, `summary`. |
| `DataRemovalResult` | struct | `failures: [String]`. |
| `KeychainInventory` | protocol, Sendable | `accounts(service:)`, `remove(service:account:)`; both `throws(DataRemovalError)`. |
| `SystemKeychainInventory` | struct | Real Keychain implementation. |
| `DataRemovalError` | enum | `keychain(Int32)`. |

The planner reads only direct entries and never follows links. A new helper or state file must be added here,
in `release/manifest.json` and in `scripts/package-release.sh`.

## KeelApp

### Entry point: `KeelMain` (`@main` struct, `@MainActor static func main()`)

1. `LaunchArguments.parse(CommandLine.arguments.dropFirst())` (type in `KeelCore`). Failure prints `keel: <error>` to
   stderr and exits **64** (`EX_USAGE`).
2. `AppInstanceIdentity(bundleIdentifier:)` picks `com.bearstouch.keel` or `com.bearstouch.keel.dev`.
3. `StateLocation.resolve(...)` then `StateLocation.prepare(_:)`; an unusable folder (file, symlink, other owner) exits
   **73** (`EX_CANTCREAT`).
4. Creates `AppDelegate(arguments:stateDirectory:)`, keeps it alive with `withExtendedLifetime`, runs `NSApplication`.

| Flag | Effect |
| --- | --- |
| `--fixture` | Fresh temporary state folder; Sparkle is never started. |
| `--state-directory <abs path>` | Separate state directory. |
| anything else starting `--` | exit 64 |

### `AppDelegate` (final class, @MainActor; `NSApplicationDelegate`, `NSWindowDelegate`, `NSMenuItemValidation`)

`applicationDidFinishLaunching` in order: disables automatic window tabbing (Keel owns its tabs), registers bundled
fonts, observes accessibility display options, runs `StaleTunnelCleanup` detached, creates the Sparkle controller if
`UpdatePolicy.isAvailable` and not `--fixture`, builds menus, attaches the SSH prompt center, loads SSH hosts, wires
`ConnectionTester`, `ConnectionSheetPresenter`, `ProfileSessionConnector` and `AppModel`, then loads settings and
profiles, restores windows and finally calls `startUpdates()`.

Menus (`buildMenus()`): Keel, File, Edit, View (tab modes, Database, Theme), Key, Connection, Window, Help. Items bound
to a `KeelShortcut` are tracked in `shortcutItems` and rebound by `applyShortcuts(_:)` when the shortcut map changes;
fixed chords come from `KeelShortcut.fixed`. Most key, editor and console actions post a notification
(`KeyListCommands`, `EditorCommands`, `ConsoleCommands`) scoped to the key window. Help holds Export Diagnostics and
Remove Keel Data (plan, confirm "Remove and Quit", execute with `SystemKeychainInventory`).

### Sparkle wiring

```swift
private var updates: SPUStandardUpdaterController?     // created with startingUpdater: false
private func startUpdates()                            // apply saved policy, subscribe to settings, startUpdater()
@objc private func checkForUpdates(_ sender: Any?)     // Keel > Check for Updates...
extension SPUUpdater: UpdaterControlling {}
```

The saved "check automatically" choice is applied before the updater starts and again on every settings Apply.
Sparkle 2 is the only external package, pinned exactly.

## Testing seams

| Seam | Injected through | Fake (`Tests/KeelReleaseTests`) |
| --- | --- | --- |
| Updater | `UpdaterControlling` | `FakeUpdater` (`UpdatePolicyTests.swift`); the same file checks `release/Info.plist` and `release/manifest.json` keys. |
| Keychain | `KeychainInventory` | `FakeKeychain` (`DataRemovalPlannerTests.swift`): never touches the user's Keychain. |
| Defaults | `storedPreferenceKeys`, `removePreference:` | Plain sets and closures. |
| Filesystem | `stateDirectory`, `home`, `fileManager` | Temporary folders, including symlinked and protected cases. |
| Built product | `ReleaseManifest.BuiltProduct`, `packageMinimumMacOS(in:)` | Constructed values and `Package.swift` text. |

`KeelApp` has no unit tests of its own; launch-argument parsing and state location are tested in `KeelCoreTests`.

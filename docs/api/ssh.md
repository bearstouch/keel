# KeelSSH, KeelAskpass, KeelAskpassMain

`KeelSSH` opens SSH tunnels by running `/usr/bin/ssh -N` with a Unix-socket forward (`TunnelManager`), keeps the saved
SSH host library, discovers `~/.ssh/config` aliases and brokers ssh's prompts. `KeelAskpass` is the library behind the
`keel-askpass` helper; `KeelAskpassMain` is its executable, bundled in `Contents/Helpers`. These modules never implement
SSH, never run a shell (argument arrays only), never emit trust-bypass options, relay every non-password prompt to the
user, and never signal a reused PID. Passwords live only in the Keychain (`Keel SSH Host`).

Behavior: [SSH tunnels](../architecture.md#ssh-tunnels), [Errors](../architecture.md#errors), [macOS](../macos.md).

Vendored code from Trellis lives in `ThirdParty/TrellisShared/KeelSSH` and `ThirdParty/TrellisShared/KeelAskpass`,
compiled into these targets through the `Sources/<Target>/TrellisShared` symlink (provenance in
`ThirdParty/TrellisShared/PROVENANCE.md`).

## Tunnels

### `TunnelManager` (actor)

Shares one ssh process per (profile, configuration) among its users, waits for the forwarded socket to accept, and
terminates the process after a grace period once the last lease is released. Strips inherited `SSH_ASKPASS*` and
`DISPLAY` from the environment.

```swift
public struct Options: Sendable {
    public var gracePeriod: Duration        // 10 s
    public var terminateTimeout: Duration   // 1 s
    public var pollInterval: Duration       // 50 ms
}
public init(launcher: any TunnelProcessLauncher = SSHProcessLauncher(), options: Options = Options(),
            environment: [String: String] = ProcessInfo.processInfo.environment, askpass: AskpassBroker? = nil,
            makeRuntime: @escaping @Sendable () throws(RuntimeDirectoryError) -> RuntimeDirectory = { ... },
            probe: @escaping @Sendable (String) -> Bool = UnixSocketProbe.accepts,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { ... })
public func acquire(profileID: UUID, configuration: SSHTunnelConfiguration, connectTimeout: Duration,
                    environment: [String: String] = [:], savedPassword: (@Sendable () async -> Data?)? = nil)
    async throws(TunnelError) -> TunnelLease
public func release(_ lease: TunnelLease)
public func shutdown() async
public func userCount(profileID: UUID) -> Int
```

`savedPassword` is called at most once per launch, for ssh's first password prompt. The connect timeout restarts after
the user answers a prompt.

| Type | Kind | Purpose |
| --- | --- | --- |
| `TunnelLease` | struct, Hashable, Sendable | `profileID`, `socketPath` to hand to `RedisEndpoint.unixSocket`. |
| `UnixSocketProbe` | enum | `accepts(_ path:) -> Bool`: whether the forward is listening. |
| `TunnelExit` | struct, Sendable | `status` (`.exited(Int32)` / `.signaled(Int32)`) and a sanitized `lastErrorLine` from stderr. |

### `SSHTunnelConfiguration` and `SSHTunnelArguments`

```swift
public struct SSHTunnelConfiguration: Hashable, Sendable {
    public var destination: String, user: String?, port: Int?, identityFile: String?
    public var redisHost: String, redisPort: UInt16
    public init(host: SavedHost, redisHost: String, redisPort: UInt16)
}
public enum SSHTunnelArguments {
    public static let executable = "/usr/bin/ssh"
    public static let forbiddenOptions: [String]   // StrictHostKeyChecking, UserKnownHostsFile, ProxyCommand, LocalCommand, ...
    public static func arguments(for configuration: SSHTunnelConfiguration, socketPath: String)
        throws(SSHTunnelArgumentError) -> [String]
    /// `LocalForward`/`RemoteForward`/`DynamicForward` specs in `ssh -G` output other than Keel's own socket (at most 3)
    public static func configuredForwards(in options: String, socketPath: String) -> [String]
}
```

`SSHTunnelArgumentError`: `invalidDestination`, `invalidUser`, `invalidIdentityFile`, `invalidPort`, `invalidRedisHost`,
`invalidRedisPort` (rejects values that ssh would parse as options).

### Processes

```swift
public protocol TunnelProcess: AnyObject, Sendable {
    var group: OwnedProcessGroup { get }     // the only way to signal it
    var exit: TunnelExit? { get }            // non-blocking
    func waitForExit() async -> TunnelExit
}
public protocol TunnelProcessLauncher: Sendable {
    func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess
    /// `ssh -G …` output, "" when the config sets no forward, or nil (default implementation: nil, no check)
    func effectiveOptions(executable: String, arguments: [String], environment: [String: String], timeout: Duration) async -> String?
}
public struct SSHProcessLauncher: TunnelProcessLauncher {  // posix_spawn, new session and process group, no shell
    public init(scanConfig: @escaping @Sendable ([String]) -> SSHConfigScan = { SSHConfigScan.scan(arguments: $0) })
}
public struct SSHConfigScan: Equatable, Sendable {
    public var forwards: Bool, matchExec: Bool, complete: Bool
    public static func scan(arguments: [String], home: String = …, read: (String) throws -> Data? = …, glob: (String) -> [String]? = SSHConfigScan.expand) -> SSHConfigScan
    public static func expand(_ pattern: String) -> [String]?   // glob(3); [] for no match, nil on failure
}
```

`SSHProcessLauncher` gives ssh no controlling terminal, `/dev/null` stdin/stdout, a stderr pipe keeping only the last
4 KiB, and no other inherited descriptors. Its `effectiveOptions` runs `ssh -G` the same way with stdout in a pipe (at
most 256 KiB) and answers nil when ssh fails, overflows or doesn't finish within the timeout (it is then terminated).
Because `ssh -G` evaluates `Match exec`, it first reads the config files with `SSHConfigScan` (the `-F` file, or
`~/.ssh/config` and `/etc/ssh/ssh_config`, following `Include` up to 16 deep and 256 files; nothing is run): with no
forward in any file it answers "" without starting ssh, and with a `Match exec` or a file it couldn't read it answers
nil (no check) rather than run the user's commands an extra time.

| Type | Kind | Purpose |
| --- | --- | --- |
| `OwnedProcessIdentity` | struct, Codable, Sendable | pid, parent pid, group, start time. `read(_:)`, `permitsSignal(current:ownerPID:)`, `isSameProcess(as:)`: a PID is signalled only while its start time still matches. |
| `OwnedProcessGroup` | final class, `@unchecked Sendable` | `signal(_:) -> Bool` refuses once reaped or reused; `markReaped(_:)`. |

### Runtime directory

| Type | Kind | Purpose |
| --- | --- | --- |
| `RuntimeDirectory` | final class, Sendable | Owner-only `keel-run-*` folder in the temp dir holding forward sockets. `create(base:name:owner:)`, `socketPath(id:)` (checks the `sun_path` length), `remove()`, `isOwnerOnlyDirectory(_:)`, `isOwnedSocket(_:)`. |
| `StaleTunnelCleanup` | struct, Sendable | `run() -> Int` removes folders and ssh processes left by a crashed run (started detached at launch). |
| `RuntimeDirectoryError` | enum | `unsafe`, `pathTooLong`, `io(Int32)`. |

## Prompts

### `PromptRelay` (actor)

Queues ssh prompts for the UI and waits for answers; an unanswered prompt resolves after `defaultTimeout` (90 s).

```swift
public init(timeout: Duration = PromptRelay.defaultTimeout, sleep: @escaping @Sendable (Duration) async throws -> Void = { ... })
public func setPresenter(_ presenter: (@Sendable (SSHPromptEvent) -> Void)?)
public func ask(_ prompt: SSHPrompt) async -> SSHPromptResponse
public func respond(to id: UUID, with response: SSHPromptResponse)
```

| Type | Values |
| --- | --- |
| `SSHPrompt` (struct, Identifiable) | `id`, `destination`, `text`, `kind`, `echo`, `fromServer` (a keyboard-interactive prompt: the server wrote the text); `Kind`: `hostKey`, `password`, `passphrase`, `code`, `confirm`, `notice`. |
| `SSHPromptResponse` | `text(Data)`, `accept`, `decline`, `cancelled`. |
| `SSHPromptEvent` | `show(SSHPrompt)`, `withdraw(UUID)`. |

### `AskpassBroker` (final class, `@unchecked Sendable`, vendored)

Listens on a per-tunnel socket that `keel-askpass` connects to. `register` returns the nonce and socket; its
`environment(helper:)` sets `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force`, `SSH_ASKPASS_KEEL_SOCKET`, `SSH_ASKPASS_KEEL_NONCE`.
Requests are accepted only from a child of the registered parent PID with the matching nonce.

```swift
public init(helperPath: String, relay: PromptRelay? = nil)
public func register(parent: @escaping @Sendable () async -> Int32?, destination: String = "",
                     password: (@Sendable () async -> Data?)?) -> Registration?
public func unregister(_ registration: Registration)
public func stop()
```

`AskpassActivity` reports `isAsking` and `hostKeyDeclined` so the manager can pause its timeout and map a declined host
key to `TunnelError.hostKeyNotAccepted`. `AskpassHelperLocation.find(executable:)` locates the bundled helper.

## KeelAskpass and KeelAskpassMain

`KeelAskpassMain/main.swift` is one line: `exit(AskpassHelper(arguments:environment:).run())`. A prompt nobody answers
exits non-zero, which ssh treats as declined; the helper never prints a guess.

| Type | Kind | Purpose |
| --- | --- | --- |
| `AskpassProtocol` | enum | Wire format: `socketVariable`, `nonceVariable`, `helperName = "keel-askpass"`, `requestLimit` 128, `promptLimit`/`replyLimit` 4096, reply tags `password` (P), `interactive` (I), `declined` (D); `request(nonce:kind:prompt:)`, `header(from:)`, `makeNonce()`. |
| `AskpassPrompt` | enum | `password`, `typed(echo:)`, `confirm`, `notice`; `classify(_:kind:)` from `SSH_ASKPASS_PROMPT`. |
| `AskpassHelper` | struct | `run() -> Int32`; injectable `exchange`, `terminal`, `write`. |
| `AskpassTerminal` / `DeviceTerminal` | protocol / struct | `show(_:)`, `ask(_:echo:)`. |

## Saved hosts (vendored)

| Type | Kind | Purpose |
| --- | --- | --- |
| `HostLibrary` | actor | `hosts`, `revision`, `loadFailed`; `load()`, `search(_:)`, `create(_:)`, `createAll(_:)`, `update(id:_:expectedRevision:)`, `setPassword(id:_:expectedRevision:)`, `password(hostID:connectionRevision:gate:)`, `delete(id:expectedRevision:)`, `applyImport(_:)` / `revertImport(_:)`, `importAliases(_:)`. Optimistic revisions; unreadable file keeps the library read-only. |
| `HostLibrary.savedPassword(for:gate:)` | nonisolated (`HostLibrary+Tunnel.swift`) | Closure for `TunnelManager.acquire(savedPassword:)`. |
| `HostStorage` / `HostFileStorage` | protocol / struct | `hosts.json` + `hosts.backup.json` in Keel's state dir. |
| `HostLibraryCodec` | enum | Versioned JSON (`currentVersion = 1`). |
| `SavedHost`, `HostDraft`, `HostDraft.Valid`, `SavedPasswordPolicy`, `HostPassword` | structs/enum | Host model, validation (`HostValidationError` per `HostField`), password limit 1023 bytes. |
| `HostSecretStore` / `KeychainHostSecretStore` / `UnavailableHostSecretStore` | protocol / structs | Keychain service `Keel SSH Host`. |
| `UserPresenceGate` / `LocalAuthenticationGate` / `UserPresenceContext` | protocols / struct | Touch ID or Mac password, fresh `LAContext` per request. |
| `SSHConfigDiscovery` | enum | `parse(_:)`, `discover(_:read:)`, `readConfig(_:)`; 1 MiB limit; warns on `Include`, `Match`, patterns. |

## Errors

Errors are typed enums; `KeelCore` maps them to the shared codes (see [Errors](../architecture.md#errors)).

| Enum | Cases |
| --- | --- |
| `TunnelError` | `invalidArguments(_)`, `runtimeDirectory(_)`, `launchFailed(Int32)`, `exited(TunnelExit)`, `timeout(Duration)`, `shutDown`, `hostKeyNotAccepted(TunnelExit)`, `configuredForwards([String])` |
| `SSHTunnelArgumentError` | see above |
| `RuntimeDirectoryError` | `unsafe`, `pathTooLong`, `io(Int32)` |
| `HostLibraryError` | `invalid(_)`, `notFound`, `conflict(expected:actual:)`, `readOnly`, `io(Int32)`, `secretStore`, `notAuthorized` |
| `HostSecretError` | `unavailable(OSStatus)` |

## Testing seams

| Seam | Injected through | Fake (`Tests/KeelSSHTests`) |
| --- | --- | --- |
| Processes | `TunnelManager(launcher:)` | `FakeLauncher` / `FakeProcess` (`TunnelManagerTests.swift`) record arguments and environment and script exits. |
| Socket readiness | `probe:` | Closure returning ready/not ready. |
| Runtime folder | `makeRuntime:` | Temporary folders per test. |
| Time | `sleep:` on `TunnelManager` and `PromptRelay` | Controllable sleep for grace periods and timeouts. |
| Askpass terminal | `AskpassHelper.terminal`, `exchange`, `write` | `ScriptedTerminal` (`AskpassTests.swift`). |
| Host storage, Keychain, user presence | `HostStorage`, `HostSecretStore`, `UserPresenceGate` / `UserPresenceContext` | In-memory stores and declining contexts. |
| ssh config | `SSHConfigDiscovery.discover(_:read:)` | Read closure returning fixture text. |

Integration against a real `sshd` runs only in `KeelIntegrationTests` containers.

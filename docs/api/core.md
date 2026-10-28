# KeelCore

`KeelCore` is the domain layer between the protocol (`KeelRESP`, `KeelSSH`) and the UI (`KeelUI`). It owns the single
data path (`DataCommandService` + `SafetyPolicy`), the command catalog, server sessions and detection, saved profiles,
Keychain secrets and versioned persistence, the SCAN key index and namespace tree, the typed value editors, the console
model, bulk delete, and app support (logging, diagnostics, launch arguments, shortcuts). It contains no views and no
`@MainActor` types: stores, sessions, the data path and job runners are actors, everything else is `Sendable` values
and stateless enums. Keys, values, fields and patterns are `Data` everywhere.

Behavior: [One data path](../architecture.md#one-data-path), [Safety policy](../architecture.md#safety-policy),
[Persistence](../architecture.md#persistence), [Key index and virtualization](../architecture.md#key-index-and-virtualization),
[Errors](../architecture.md#errors), [Functional requirements](../requirements/functional.md).

Invariants every contributor must keep:

- Every server command from the browser, editors, console and bulk jobs goes through
  `DataCommandService.execute`, `executeTransaction` or `stream`. The policy runs before a connection is opened or a byte
  is written; a refused command sends nothing. No code outside `KeelCore`'s data path (and the session setup probes in
  `ProfileSessionConnector`) sends on a `RedisConnection`.
- The browser enumerates with `SCAN` only; values load in bounded pages. `KEYS`, `MONITOR`, `SUBSCRIBE`, scripts and admin
  commands are console-only.
- Display text (`KeyDisplay`, `RedisCliFormatter`, `ValueText`) is never turned back into command arguments.
- A lost reply to a possible write is `OUTCOME_UNKNOWN`: re-read, never re-send.
- Every buffer that grows with server data has a cap (see the limits quoted per type below).
- Values, key names and console text are never logged or persisted; logs carry codes and counts (`KeelLog`).

## The data path

### `DataOperation` (enum, Sendable, Equatable)

A typed read or write that editors, the browser and jobs ask for. Each case compiles to exactly one command
(`arguments: [Data]`) that the policy classifies like any other; bytes pass through unchanged. Editors never build
command strings.

| Group | Cases (command) |
| --- | --- |
| Browser / metadata | `scan(cursor:match:count:type:)`, `type`, `pttl`, `memoryUsage` (`MEMORY USAGE … SAMPLES 0`), `databaseSize` (`DBSIZE`), `info(section:)`, `objectEncoding`, `length(key:command:)`, `expireTime` (`PEXPIRETIME`, probed), `exists` |
| Value reads | `get`, `getRange`, `hashGetAll`, `hashScan`, `hashGet`, `listRange`, `setMembers`, `setScan`, `setIsMember`, `sortedSetRange(… byScore:)`, `sortedSetScan`, `sortedSetScore`, `streamRange(… reverse:)`, `streamInfo` |
| Writes | `stringSet(keepTTL:)`, `stringCreate` (`SET … NX [PX]`), `hashSetField`, `hashDeleteFields`, `listPush`, `listSet`, `listRemove`, `listPop`, `listInsert`, `setAdd`, `setRemove`, `sortedSetAdd(existingOnly:)`, `sortedSetIncrement`, `sortedSetRemove`, `streamAdd`, `streamDelete`, `rename(overwrite:)`, `expire`, `expireAt`, `persist`, `delete(keys:)` (`UNLINK`), `flushDatabase(async:)`, `flushAll(async:)` |

Nested value types: `DataOperation.ScoredMember { score: Double; member: Data }`,
`DataOperation.FieldValue { field: Data; value: Data }`. `LengthCommand` (`STRLEN`, `HLEN`, `LLEN`, `SCARD`, `ZCARD`,
`XLEN`) lives in `KeyEditing.swift` and maps from `KeyType`.

### `DataCommand`, `DataContext`, `DataCommandResult`

```swift
public enum DataCommand: Sendable, Equatable {
    case operation(DataOperation)
    case raw([Data])                 // console lines after ConsoleTokenizer
    public var arguments: [Data] { get }
}

public struct DataContext: Sendable, Equatable {
    public var profile: SafetyProfile
    public var database: Int
    public var consoleID: UUID?       // required for .console
    public var jobID: UUID?           // required for .bulk
    public var confirmation: CommandConfirmation?
    public init(profile: SafetyProfile, database: Int = 0, consoleID: UUID? = nil, jobID: UUID? = nil, confirmation: CommandConfirmation? = nil)
}

public struct DataCommandResult: Sendable, Equatable {
    public var reply: RESPValue       // a server error (-WRONGTYPE) is a value, not a throw
    public var safetyClass: SafetyClass
    public var role: ConnectionRole
    public var isUnknownCommand: Bool { get }
}
```

### `CommandOrigin` (enum, Sendable, Hashable)

`editor`, `browser`, `console`, `bulk`. Origin never relaxes a rule; it selects what may run at all and which
connection role carries it: editor and browser share `.browser(database:)`, the console uses `.console(id)` (and
`.stream(id)` for streaming), each bulk job uses `.job(id)`.

### `DataCommandService` (actor)

The single entry point for every server command.

```swift
public actor DataCommandService {
    public let session: ServerSession
    public private(set) var catalog: CommandCatalog
    public private(set) var isReadOnlyLocked: Bool
    public init(session: ServerSession, catalog: CommandCatalog = .bundled)

    public func execute(_ command: DataCommand, origin: CommandOrigin, context: DataContext) async throws(DataCommandError) -> DataCommandResult
    public func verdict(_ command: DataCommand, origin: CommandOrigin, context: DataContext) async -> SafetyVerdict   // sends nothing
    public func executeTransaction(_ writes: [DataOperation], unchanged watch: WatchGuard?, context: DataContext) async throws(DataCommandError) -> DataCommandResult
    public func stream(_ command: DataCommand, context: DataContext) async throws(DataCommandError) -> AsyncStream<RESPValue>
    public func stopStream(console: UUID) async
    public func closeConsole(_ console: UUID) async
    public func inTransaction(console: UUID) async -> Bool   // a MULTI is open on the console's connection (FR-SF08 measures nothing then)
    public func supports(_ capability: ServerCapability, context: DataContext) async -> Bool
    public func refreshCatalog(context: DataContext) async throws(DataCommandError)
    public func lockReadOnly()
    public func observeWrites(_ observer: (@Sendable (WriteEvent) -> Void)?)
}
```

- `execute`: resolves the command in `catalog`, evaluates `SafetyPolicy.evaluate` with the effective profile, picks the
  role, then calls `ServerSession.send`. Any verdict other than `.allow` throws `.refused(verdict)` before a connection
  is opened. Console commands flagged `blocking` run with no command timeout (Stop closes the connection). Refusals log
  at info, failures at error, code only.
- `verdict`: what the policy says now, without sending. The console uses it to measure and confirm first; `execute`
  evaluates again, so a verdict never lets anything through on its own. Both add one rule the pure policy can't see: on
  a read-only (or locked) profile a console's `EXEC` is `READ_ONLY` while its open `MULTI` has queued a command
  read-only refuses (`SafetyPolicy.readOnlyRefused`), so writes queued before the lock never run; `DISCARD` ends it.
- `executeTransaction`: an editor save. Every write and every guard read passes the policy (origin `.editor`) before the
  first byte; guard reads must be non-writing. With a `WatchGuard` it sends `WATCH key`, repeats the reads and compares
  (RESP2/RESP3 null and score spellings are equal), then pipelines `MULTI … EXEC` on the pinned browser connection.
  A mismatch or nil `EXEC` throws `.conflict` and writes nothing; a missing `MULTI` reply is `OUTCOME_UNKNOWN`.
  Transactions on one role are serialized (an `EXEC` ends every `WATCH` on its connection); a stray `WATCH` is always
  `UNWATCH`ed. `WATCH`/`MULTI`/`EXEC`/`UNWATCH` are the service's own framing; callers can never send them.
- `stream`: `MONITOR` / `(P|S)SUBSCRIBE` on the console's `stream` connection. Anything not classed `.streaming` is
  refused; `stopStream` closes that connection, which ends the stream.
- `closeConsole`: cancels a blocking console command by closing its connections; the command fails and is never re-sent.
- `supports`: lazily creates a `CapabilityProbe` on the browser connection, caches results; a probe that can't be made
  answers false (callers take the portable fallback).
- `refreshCatalog`: `COMMAND` and `COMMAND DOCS` through `execute`, merged over the bundled catalog.
- `lockReadOnly`: one-way; every later command is evaluated as read-only regardless of the context the caller holds.
  Turning read-only off takes a new session. `executeTransaction` re-checks the lock after each suspension.
- `observeWrites`: one observer receives `WriteEvent.sent` (a data-changing command passed the policy) and
  `.serverRefused` (the server refused writes: `READONLY`, or an ACL `NOPERM … permissions to run` on a plain write).

Related types:

```swift
public struct WatchGuard: Sendable, Equatable {      // what a guarded save expects to find
    public var key: Data
    public var reads: [DataOperation]
    public var expected: [RESPValue]                 // same count as reads
}
public enum WriteEvent: Sendable, Equatable { case sent, serverRefused }
public enum ServerReadOnly {
    public static func refusesWrites(_ reply: RESPValue, of safetyClass: SafetyClass = .write) -> Bool
}
```

### `DataCommandError` (enum, Error, Sendable, Equatable)

| Case | Meaning | `code` |
| --- | --- | --- |
| `refused(SafetyVerdict)` | Policy refused; nothing sent | `READ_ONLY`, `BLOCKED_COMMAND`, `CONFIRMATION_REQUIRED` |
| `invalidRequest(String)` | Malformed request (no arguments, console/bulk command without its id, wrong database); nothing sent. Editors also use it for shape errors and "key no longer exists" | `INVALID_PARAMS` |
| `connection(ConnectionFailure)` | The role's connection couldn't open; nothing sent | `TIMEOUT` or `CONNECTION_FAILED` |
| `command(RedisError)` | Failed, timed out or closed around the command | `RedisError.code` (`OUTCOME_UNKNOWN`, `NOT_CONNECTED`, `TIMEOUT`, `CANCELLED`, `PROTOCOL_ERROR`, `LIMIT_EXCEEDED`, `CONNECTION_FAILED`) |
| `conflict` | Guarded save found the key changed; nothing written | `CONFLICT` |

## Safety

### `SafetyPolicy` (enum, pure)

```swift
public enum SafetyPolicy {
    public static func classify(_ arguments: [Data], command: CommandInfo?) -> SafetyClass
    public static func evaluate(_ arguments: [Data], command: CommandInfo?, origin: CommandOrigin,
                                profile: SafetyProfile, database: Int, confirmation: CommandConfirmation?) -> SafetyVerdict
}
public enum GlobPattern {                            // port of Redis/Valkey stringmatchlen on bytes; exactly `*` matches every key
    public static func matches(_ pattern: Data, _ subject: Data) -> Bool
    public static func matchesEverything(_ pattern: Data) -> Bool   // every non-empty key: `*`, `?*`, `[^]*` (FR-SF05)
}
```

Pure: the same arguments, catalog entry, origin and context always give the same verdict. Order of evaluation:

1. Read-only profile blocks `write`, `destructive`, `script`, `admin` and `unknown` from every origin (fail closed).
2. `read`, `write`, `neutral` are allowed from any origin.
3. `destructive` needs a matching `CommandConfirmation` (typed text: key count, `dbN`, or the profile name).
4. `script` is console-only; `admin` and `keys` are console-only and need a plain confirmation.
5. `streaming`, `session` and `unknown` are console-only.
6. `forbidden` (`CLIENT REPLY`, empty arguments) is never sent.

Classification rules are fixed before flags: streaming names (incl. the unsubscribe commands), `KEYS`,
`FLUSHDB`/`FLUSHALL`, `DEL`/`UNLINK` with more than one key, session names (`SELECT`, `HELLO`, `AUTH`, `MULTI`, `WATCH`,
`CLIENT TRACKING`, …). Then `admin` or `dangerous`+`write` is admin; scripting group without `readonly` is script;
`write` or `may_replicate` without `readonly` is write; `readonly` is read; a flagless command is `neutral` only when it
has a core group, otherwise `unknown`.

### `SafetyClass` (enum, String raw value)

`read`, `write`, `destructive`, `script`, `admin`, `keys`, `streaming`, `session`, `neutral`, `forbidden`, `unknown`.
`mayWrite` is false only for `read`, `keys`, `neutral`; it decides whether an interrupted command reports
`OUTCOME_UNKNOWN`.

### Profiles, verdicts and confirmations

```swift
public struct SafetyProfile: Sendable, Equatable {
    public var name: String
    public var readOnly: Bool
    public var production: Bool       // label treated as production (FR-SF02)
    public var server: String?        // named in production typed confirmations
}

public enum SafetyVerdict: Sendable, Equatable {
    case allow(SafetyClass)
    case readOnly(message: String)
    case blocked(message: String)
    case confirmationRequired(ConfirmationRequest)
    public var isAllowed: Bool { get }
    public var code: String? { get }  // nil when allowed
}

public struct ConfirmationRequest: Sendable, Equatable {
    public enum Operation { case deleteKeys(count: Int), flushDatabase(Int), flushAll, admin(command: String), keys }
    public var operation: Operation
    public var typedText: String?     // nil: plain confirmation
    public var message: String        // never a key name or value
}

public struct CommandConfirmation: Sendable, Equatable {
    public enum Scope { case command([Data]), keys(Set<Data>), pattern(Data) }
    public var scope: Scope
    public var database: Int
}
```

A `CommandConfirmation` covers only its database and scope: `.command` matches the arguments byte for byte; `.keys`
covers multi-key `DEL`/`UNLINK` whose keys are all in the selection; `.pattern` covers `DEL`/`UNLINK` whose keys all
match the glob, and never a glob every key matches (`*`, `?*`, `[^]*`: that is `FLUSHDB`).

### `TypedConfirmation` (struct, Sendable)

The shared typed-confirmation sheet's model (FR-SF03). The button enables only when `matches(_:)` is exact (same case,
no trimming; compared as bytes). Operations: `deleteKeys(count:)`, `deletePattern(Data)`, `flushDatabase(Int)`,
`flushAll`. Production profiles add `serverLine`.

```swift
public init(operation: Operation, profile: SafetyProfile, database: Int)
public init?(_ request: ConfirmationRequest, profile: SafetyProfile, database: Int)   // nil for plain confirmations
public var expected: Data; public var expectedText: String; public var prompt: String
public func matches(_ typed: String) -> Bool
```

### `MultiKeyDelete` (enum)

Deleting a browser selection (FR-SF04): `UNLINK` in batches of `batchSize = 500`, in order, stopping at the first
failure. A batch with a lost reply is never re-sent and its keys stay out of `removed`.

```swift
public static func confirmation(for keys: [Data], database: Int) -> CommandConfirmation   // scope .keys
public static func request(for keys: [Data], profile: SafetyProfile, database: Int) -> TypedConfirmation
public static func run(_ keys: [Data], service: DataCommandService, context: DataContext, origin: CommandOrigin = .browser) async -> Report
// Report { requested, removed: [Data], deleted, failure: Failure?, isComplete }
// Failure: .command(DataCommandError) | .server(String) -> SERVER_ERROR | .cancelled -> CANCELLED
```

### `ComplexityWarning` (struct, Sendable)

The console's O(N) warning (FR-SF08) for `KEYS`, `SMEMBERS`/`HGETALL`/`LRANGE` over `threshold = 10_000` elements and
`FLUSHALL` without `ASYNC`. Sizes are read through the data path on the console's own connection (`DBSIZE`, `SCARD`,
`HLEN`, `LLEN`, `INFO keyspace`); an unreadable size gives no warning (the policy's confirmation still applies). While the console's connection has a
`MULTI` open nothing is measured and `check` returns nil, so no size read is queued in the user's transaction.

```swift
public static func check(_ arguments: [Data], service: DataCommandService, origin: CommandOrigin = .console, context: DataContext) async -> ComplexityWarning?
// kind: .keys(databaseSize:) | .wholeValue(command:elements:) | .flushAllSync(keys:)
```

### `ServerReadOnly`

See the data path above: decides when a server reply means the server itself refuses writes (replica `READONLY`, ACL
refusal of a plain write; key-pattern ACL refusals do not count).

## Command catalog

`CommandCatalog` (struct, Sendable) maps lowercase command names (subcommands as `container|sub`) to `CommandInfo`.

```swift
public struct CommandFlags: OptionSet { static let write, readonly, admin, dangerous, blocking, pubsub, mayReplicate, restrictive }
public enum CommandAccess: String { case read, write, other, unknown; var mayWrite: Bool }
public struct CommandInfo: Sendable, Equatable {
    public var name: String; public var arity: Int; public var flags: CommandFlags
    public var firstKey: Int; public var lastKey: Int; public var keyStep: Int; public var movableKeys: Bool
    public var docs: CommandDocs?                    // summary, since, group, complexity, arguments
    public var access: CommandAccess; public var isSubcommand: Bool; public var displayName: String; public var syntax: String
    public func acceptsArgumentCount(_ count: Int) -> Bool
    public func keyIndexes(argumentCount count: Int) -> [Int]
}
public struct CommandCatalog: Sendable {
    public static let bundled: CommandCatalog       // Resources/Commands/commands.json
    public static let bundledFormatVersion = 1
    public init(commands: some Sequence<CommandInfo>)
    public var count: Int; public var commandNames: [String]
    public func subcommandNames(of container: String) -> [String]
    public func command(named name: String) -> CommandInfo?
    public func resolve(_ arguments: [Data]) -> CommandInfo?          // container + subcommand aware
    public func access(of arguments: [Data]) -> CommandAccess
    public func merging(live: CommandCatalog) -> CommandCatalog
    public static func load(bundled: CommandCatalog = .bundled, send: Send) async throws(RedisError) -> CommandCatalog
    public static func live(commandReply reply: RESPValue) -> CommandCatalog?
}
```

- The bundled catalog is generated by `scripts/generate-command-catalog.py` from Redis and Valkey `src/commands`
  sources (`generatedFrom`, `checkedAgainst`, `missingFromCheck` in the JSON). A missing or newer-format resource is a
  build defect (`preconditionFailure`), caught by `CommandCatalogTests`. Never edit `commands.json` by hand.
- The live catalog (`COMMAND`, `COMMAND DOCS`) is merged over the bundled one per session; a server that refuses those
  keeps the bundled catalog. A command missing from both is `unknown` and fails closed on read-only profiles.

## Sessions and connecting

### `ConnectionRole` (enum, Sendable, Hashable)

`browser(database:)` (SCAN, metadata, value pages, editor writes; one per database), `console(UUID)`, `stream(UUID)`,
`job(UUID)`. `description` never contains a UUID.

### `ServerSession` (actor)

The connections of one server session, keyed by role. Each opens on first use through the injected `Open` closure
(connect, handshake, `SELECT`); concurrent callers share one open; a failed or closed connection is replaced on next
use and nothing in flight is re-sent.

```swift
public typealias Open = @Sendable (ConnectionRole, _ database: Int) async throws(ConnectionFailure) -> RedisConnection
public init(open: @escaping Open)
public func readyRoles() async -> Set<ConnectionRole>
public func connection(for role: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection
public func send(_ arguments: [Data], mayWrite: Bool, role: ConnectionRole, database: Int,
                 bindsDatabase: Bool = true, selecting: Int? = nil, timeout: Duration? = nil,
                 transaction: TransactionStep? = nil) async throws(DataCommandError) -> RESPValue
public func openTransaction(_ role: ConnectionRole) async -> OpenTransaction?
public func stream(_ arguments: [Data], role: ConnectionRole, database: Int) async throws(DataCommandError) -> AsyncStream<RESPValue>
public func pinnedConnection(for role: ConnectionRole, database: Int) async throws(DataCommandError) -> RedisConnection
public func close(_ role: ConnectionRole) async
public func closeAll() async
```

`send` tracks each connection's database: a command that binds a database runs only when the connection is known to be
on it (`INVALID_PARAMS` otherwise); a console `SELECT`/`RESET` clears the known database until the server answers.
It also follows a console's `MULTI` from the replies (`TransactionStep`: `begin` on `MULTI` `OK`, `end` on `EXEC` /
`DISCARD` / `RESET` / `QUIT`, `queue(mayWrite:)` on a `QUEUED` reply); `openTransaction` answers nil once the connection
it was opened on is closed or replaced. `OpenTransaction.queuedWrite` says whether a command read-only refuses was queued.
`ServerSession.send` is the data path's transport, not an entry point: call `DataCommandService` instead.

### `SessionConnecting` / `ProfileSessionConnector` / `ConnectedServer`

```swift
public protocol SessionConnecting: Sendable {
    func connect(profileID: UUID, database: Int) async -> Result<ConnectedServer, ConnectionFailure>
}
public struct ConnectedServer: Sendable {
    public var session: ServerSession; public var service: DataCommandService; public var identity: ServerIdentity
    public var databaseCount: Int?; public var safety: SafetyProfile; public var separator: NamespaceSeparator?
    public var close: @Sendable () async -> Void      // idempotent; releases the tunnel
}
```

`ProfileSessionConnector` is the real connect of a saved profile: Keychain password bound to the profile's
`connectionRevision`, TLS with the recorded CA (`KnownCAStore`, a changed CA asks through `confirmCAChange`), client
identity, SSH tunnel lease from `TunnelManager` (keyed by profile, shared across tabs), then a `ServerSession` whose
opener connects, handshakes and selects. On the first browser connection it identifies the server (refusing below the
minimum with `UNSUPPORTED_SERVER`), loads the live catalog and asks `CONFIG GET databases` (best effort). Any failure
closes what was opened. A cancelled calling task (the tab closed or disconnected while connecting) cancels the tunnel
acquire, opens nothing more and fails with `ConnectionFailure.cancelled` after closing what was opened. Settings (timeouts, client name, console RESP version) are read once per connect; only the
console connection uses the console protocol setting, every other role stays on RESP3. All collaborators are injected
through `init` (`makeConnection`, `detector`, `settings`, `resolveSavedHost`, …).

### `ConnectionTester` / `ConnectionTesting`

Test Connection for the connection sheet: `test(_ settings:password:profileID:) async -> Result<ConnectionTestResult, ConnectionFailure>`.
`ConnectionTestResult` carries `identity`, `roundTrip`, `tlsVerified` and a `summary`. Defaults:
`defaultConnectTimeout = 10 s`, `defaultCommandTimeout = 30 s`. `ResolvedTunnel` is a tunnel resolved from
`TunnelSettings` (ssh configuration, display destination, saved-password lookup).

### `ConnectionFailure` (struct, Error) and `ConnectionErrorCategory`

User-facing connect failure (FR-CN10): `category`, `message`, `suggestion`, optional `phase` (timeouts), scrubbed
`serverError`, `tunnelExit`. Messages never contain the password; server text loses echoed arguments. Mapping
initializers: `init(connecting: RedisError, …)`, `init(handshake: HandshakeError, …)`, `init(tunnel: TunnelError, destination:)`,
`init(caFile: KnownCAError)`, `init(unsupported: ServerKind, version:minimum:)`; `cancelled` (`CONNECTION_FAILED`, never shown in a tab). Categories are listed in the error table.

### Server detection

```swift
public enum ServerKind: String, Codable, CaseIterable { case redis, valkey, dragonfly, unrecognized; var displayName: String }
public struct ServerVersion: Comparable { init?(_ text: String); var major: Int; var minor: Int }
public enum ServerMode: String, Codable { case standalone, replica, cluster, sentinel }
public struct ServerIdentity: Sendable, Equatable {
    kind, version, redisCompatibleVersion, mode, role
    var displayName: String; var showsClusterBanner: Bool
}
public enum InfoFields { static func parse(_ text: String) -> [String: String]; static func text(of reply: RESPValue) -> String? }
public struct ServerDetectionRules: Decodable { static let bundled }       // Resources/ServerDetection.json
public struct ServerDetector: Sendable {
    public init(rules: ServerDetectionRules = .bundled)
    public func detect(info: String) throws(ConnectionFailure) -> ServerIdentity
    public func detect(fields: [String: String]) throws(ConnectionFailure) -> ServerIdentity
}
```

`ServerDetection.json` is an ordered rule list: Dragonfly (`dragonfly_version`), Valkey (`server_name: valkey` or
`valkey_version`), Redis (`redis_version`, `minimumVersion: "6.0"`). First match wins; order matters because Valkey
and Dragonfly also report `redis_version`.

### `CapabilityProbe` (actor) and capabilities

Features that vary within the supported range are probed, never inferred from a version (FR-CN12, INT-02).
`ServerCapability`: `memoryUsage`, `objectEncoding`, `commandDocs`, `zrangeByScore`, `xrangeExclusive`, `pexpireTime`,
`evalReadOnly`. Probes are read-only and keyed on a random `keel:probe:<uuid>` name.

```swift
public init(probeKey: Data = …, send: @escaping Send)
public init(connection: RedisConnection)
public var cached: CapabilitySet
public func status(_ capability: ServerCapability) async throws(RedisError) -> CapabilityStatus   // .available | .unavailable(serverError:)
public func probeAll() async throws(RedisError) -> CapabilitySet
```

`CapabilitySet` builds portable commands (`zrangeByScore(...)`, `xrangeAfter(...)`, `expiryQuery(key:)`);
`ExpiryQuery`/`KeyExpiry` turn `PEXPIRETIME` or `PTTL` replies into an expiry. `CapabilityStatus.unavailableCode` is
`UNSUPPORTED`. Do not use a Redis-only (7.4+/8.x) command without adding a capability here.

### `InfoReport` / `InfoOverview`

`InfoReport(text:)` parses `INFO` into `InfoSection`s of `InfoField`s, with `subscript(field:)`, `section(_:)`,
`sectionStatuses` (against `expectedSections`) and `rawLines(matching:)`; `InfoReport.load(service:context:)` reads it
through the data path (`Result<InfoReport, KeyIndexError>`). `InfoOverview(report:now:)` derives the Info mode's
`tiles: [InfoTile]`, `databases: [InfoDatabase]` and `health: [InfoHealthItem]`; missing fields show `InfoOverview.missing`.

## Profiles, secrets and persistence

### `ConnectionProfile` and friends (Codable, Sendable values)

- `ConnectionSettings`: name, host, port, username, database, TLS (`TLSSettings`: `serverName`, `caFile`,
  `skipVerification`), `tunnel: TunnelSettings?`, label, read-only, timeouts, separator. `validated()` throws
  `ProfileStoreError.invalid(ProfileField)`; limits `nameLimit = 128`, `databaseRange = 0...65_535`,
  `timeoutRange = 100...600_000` ms. `connectionKey` (host, port, username, TLS server name, tunnel) defines "same
  server"; `weakensTransport(from:)` detects a TLS/tunnel downgrade.
- `ConnectionProfile`: `id`, `settings`, `folderID`, `revision`, `connectionRevision`, `hasPassword`, `hasTLSSecret`,
  `importedFrom` (optional: the export-file ID an imported profile was added under; collisions match it too),
  `savedHostBinding` (`SavedHostBinding`: the saved SSH host's destination, user, port and identity file the password
  was saved through, FR-CN21).
- `ProfileFolder`, `ProfileLabel` (`LabelColor`, name ≤ 40, `treatAsProduction`), `ConnectionsDocument`
  (`connections.json`, `currentVersion = 1`).

### `ProfileStore` (actor)

Single owner of `connections.json` and the profiles' Keychain items. Every mutation validates, writes the Keychain,
then the metadata; a failed metadata write restores the previous Keychain values. Mutations are serialized; editors pass
`expectedRevision` and get `.conflict` when stale. A change to the connection key advances `connectionRevision` and
removes the saved password. `resolveSavedHost` (the app passes `HostLibrary`'s hosts) binds a password saved through a
saved SSH host to where the host connects: `password(profileID:connectionRevision:)` returns nil once the host is gone
or re-pointed, and removes the stale password; a password set for a host that can't be resolved is `.invalid(.tunnel)`.

```swift
public init(persistence: Persistence<ConnectionsDocument>, secrets: any SecretStore, makeID: @escaping @Sendable () -> UUID = { UUID() },
            resolveSavedHost: @escaping @Sendable (UUID) async -> SavedHost? = { _ in nil })
public init(directory: URL, secrets: any SecretStore = KeychainSecretStore(), resolveSavedHost: @escaping @Sendable (UUID) async -> SavedHost? = { _ in nil })
public func load() async -> LoadOutcome                                   // .ready | .recovery(reason:backupAvailable:)
public func recover(_ choice: RecoveryChoice) async throws(ProfileStoreError)
public func changes() -> AsyncStream<ConnectionsDocument>
public func password(profileID: UUID, connectionRevision: UInt64) async throws(ProfileStoreError) -> Data?
public func create(_ settings: ConnectionSettings, folderID: UUID? = nil, password: Data? = nil, identity: ImportedTLSIdentity? = nil) async throws(ProfileStoreError) -> ConnectionProfile
public func update(_ id: UUID, _ settings: ConnectionSettings, password: PasswordChange = .keep, identity: TLSIdentityChange = .keep, expectedRevision: UInt64) async throws(ProfileStoreError) -> ConnectionProfile
public func duplicate(_:) / delete(_:expectedRevision:) / move(_:toFolder:position:expectedRevision:)
public func createFolder(named:) / renameFolder / setFolderCollapsed / moveFolder / deleteFolder
public func renameLabel(_:to:) / setTreatAsProduction(_:_:)
public func export() -> ProfileExport; public func previewImport(_:) -> ProfileImportPreview
public func importProfiles(_ export: ProfileExport, policy: ProfileImportPolicy) async throws(ProfileStoreError) -> ProfileImportResult
```

`passwordByteLimit = 4096`. `ProfileStoreError`: `invalid`, `notFound`, `conflict(expected:actual:)`, `readOnly`,
`persistence`, `secretStore`, `invalidImport`. `PasswordChange`: `keep`, `set(Data)`, `remove`. `TLSIdentityChange`: `keep`,
`set(ImportedTLSIdentity)`, `remove`; `removeTLSIdentity` (init, the app passes `TLSIdentityImporter.removeIdentity`)
deletes a replaced identity Keel added once no profile uses it.

### `SecretStore` (protocol) / `KeychainSecretStore`

```swift
public enum ProfileSecret: String { case password = "Keel Connection", tls = "Keel TLS" }   // account = profile UUID
public protocol SecretStore: Sendable {
    func read(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError) -> Data?
    func write(_ data: Data, _ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError)
    func remove(_ secret: ProfileSecret, profileID: UUID) throws(SecretStoreError)   // missing is not an error
}
```

`KeychainSecretStore` writes generic passwords, *when unlocked, this device only*. Secrets never go anywhere else. The
`Keel SSH Host` service belongs to `KeelSSH`.

`LaunchSecrets(arguments:)` picks the stores for a launch: `usesKeychain`, `profiles: any SecretStore`,
`hosts: any HostSecretStore`, `identities: TLSIdentityImporter` and `clientIdentity: (UUID) -> TLSClientIdentity?`
(through `identities`). Normally they are `KeychainSecretStore`, `KeychainHostSecretStore` and
`TLSIdentityImporter()`; a `--fixture` run gets `InMemorySecretStore`, `InMemoryHostSecretStore` and
`TLSIdentityImporter(keychain: NoTLSIdentityKeychain())`, so it never reads or writes the Keychain. A `SecIdentity`
needs a keychain, so a fixture run's certificate import fails with `unsupportedKey(NoTLSIdentityKeychain.message)`
after the in-memory checks, and it connects without a client identity.

### `Persistence<Document>` (actor) and `PersistenceCodec`

Single writer of one state file (`PersistedFile`: `connections`, `hosts`, `windows`, `settings`, `known-ca`).
Atomic owner-only writes through vendored `OwnerOnlyStorage` (files 0600), a last-known-good backup (none for
`known-ca`), a 300 ms debounce, and caller-assigned sequences so an older save never replaces a newer one. Saving is off
until `load()` saw a usable or missing file; a newer-version file stays read-only for the session.

```swift
public protocol PersistedDocument: Codable, Sendable {
    static var file: PersistedFile { get }
    static var currentVersion: Int { get }          // bump on every format change
    static func migrate(from version: Int, decoder: any Decoder) throws -> Self
}
public init(directory: URL, debounce: Duration = .milliseconds(300), sleep: …, beforeReplace: …)
public func load() -> PersistenceLoadResult<Document>     // .missing | .loaded | .recovery(reason:backup:)
public func recover(_ choice: RecoveryChoice) throws(PersistenceError) -> Document?
public func save(_ document: Document, sequence: UInt64) throws(PersistenceError) -> Bool
public func scheduleSave(_ document: Document, sequence: UInt64)
public func flush() throws(PersistenceError)
public var isWritable: Bool; public private(set) var lastSaveError: PersistenceError?
```

`PersistenceCodec` adds the `schemaVersion` envelope and caps files at `byteLimit = 4 MiB` and `depthLimit = 128`.
`PersistenceError`: `corrupt`, `newerVersion(Int)`, `readOnly`, `backupUnavailable`, `tooLarge`, `io(Int32)`. An
unreadable original is preserved as `<name>.corrupt.<uuid>.json` before `startEmpty` replaces it.

### Other state

| Type | Kind | Purpose |
| --- | --- | --- |
| `InstanceLock` | final class | MAC-17: `init(directory:)` takes an exclusive `flock` on `instance.lock` (0600, `O_NOFOLLOW`) and records the PID; `Failure.held(path:owner:)` when another process holds it, `.unusable(path:errno:)` for a link, folder or foreign file; `release()` or deinit drops it |
| `StateLocation` | enum | `resolve(arguments:identity:applicationSupport:temporary:)` picks `--state-directory`, a fresh fixture folder, or `Application Support/<bundle id>`; `prepare(_:)` creates it 0700 and refuses a file, symlink or foreign-owned folder (`Failure`) |
| `KnownCAStore` | actor | Owner of `known-ca.json` (FR-CN04): `check(profile:caFile:)` returns `CATrust.trusted(anchors:)` or `.changed(CAChange)`; only `accept(_:)` or `anchors(profile:caFile:confirm:)` turns a change into anchors; `forget(profile:)`. `CAFile.read` caps at 4 MiB. `CAFingerprint` is SHA-256 hex |
| `TLSIdentityImporter` | struct | Imports a client identity from PKCS#12 or PEM cert + key (PKCS#8 incl. PBES2, PKCS#1, SEC1; `PrivateKeyDecoder`, `DER` internal) into the login Keychain: `importPKCS12(_:passphrase:)` / `importPEM(certificate:privateKey:passphrase:)` return an `ImportedTLSIdentity` (`reference`, `summary`, `isNew`) that `ProfileStore` saves; `discard(_:)`, `removeIdentity(reference:)`, `clientIdentity(profileID:)`, `passphrase(profileID:)`, `subject(profileID:)` read `Keel TLS`, which only `ProfileStore` writes. Errors: `TLSIdentityImportError` |
| `TLSIdentityKeychain` / `SystemTLSIdentityKeychain` | protocol / struct | Keychain calls for identity import; never touches the system keychain or trust settings |
| `ProfileExport` | struct | `keel-profiles` export format v1 (folders + settings, never secrets); `validated()`, `encoded()`, `decode(_:)`; `ProfileImportPolicy`, `ProfileImportPreview`, `ProfileImportResult`, `ProfileImportError` |
| `RedisURL` | struct | Parses and prints `redis://` / `rediss://` URLs (`isCandidate`, `init(parsing:)`, `init(settings:)`, `string`, `applied(to:)`); unknown query parameters are reported, not applied |
| `SettingsDocument` | PersistedDocument | `settings.json`: `ThemeChoice`, `BrowserSettings` (separator, page size, auto-page limit), `EditorSettings` (`DefaultViewer`), `ConsoleSettings` (RESP 3 or 2), `AdvancedSettings` (timeouts, client name), shortcuts. `SettingsSnapshot` (final class, lock-backed) is the applied copy read off the main actor |
| `WindowsDocument` | PersistedDocument | `windows.json`: `SavedWindow` / `SavedTab` / `SavedFrame`, recents; caps 64 windows, 128 tabs each, 8 recents; `restorable(profileIDs:)`. `ReconnectPolicy.reconnectsOnLaunch` never auto-reconnects production |

Never persist values, key names from browsing, console output or history, passwords or tokens.

## Key browsing

### `KeyIndex` (actor)

The browser's SCAN results for one database. Keys live back to back in one byte arena with an end-offset array, a
parallel packed metadata array and an open-addressing dedup table; display strings are never stored. Every page is one
`SCAN` sent through the data path from `.browser`. Bounds: `KeyIndexConfiguration` (`defaultPageSize = 1_000`,
`maximumPageSize = 100_000`, `defaultLimit = 1_000_000`, `maximumLimit = 10_000_000`); measured sizes kept for at most
65,536 rows.

```swift
public init(service: DataCommandService, context: DataContext, configuration: KeyIndexConfiguration = .init(),
            separator: NamespaceSeparator? = .default, defaults: (@Sendable () -> BrowserSettings)? = nil)
public var count: Int; public var status: KeyIndexStatus; public private(set) var generation: Int
public func key(at index: Int) -> Data
public func keys(in range: Range<Int>) -> [Data]
public func keys(at indices: [Int], generation expected: Int) -> [Data]?     // nil when indices went stale
public func metadata(at index: Int) -> KeyMetadata
public func loadMore() async -> KeyIndexStatus
public func autoPage() async -> KeyIndexStatus              // with a page in flight, keeps that run going (clears a stop or pause)
public func pause(); public func continueScanning() async -> KeyIndexStatus
public func stopAutoPage()                                     // ends the loop after the page in flight; mode stays auto
public func setPagingMode(_ mode: KeyPagingMode)               // ⋯ → Auto-page off: manual (a paused scan goes idle)
public func restart(filter: KeyFilter? = nil); public func switchDatabase(_ database: Int)
public func databaseSize() async -> Result<Int, KeyIndexError>
public func index(of key: Data) -> Int?; public func presence(of key: Data) async -> KeyPresence
public func add(key: Data, type: KeyType) -> Bool; public func remove(keys: some Sequence<Data>) -> Int
public func setSeparator(_:); namespaceChildren(of:); namespaceEntries(_:fullNames:); namespaceAncestors(ofKey:); namespaceKeyCount(of:); namespacePath(of:)
public func metadataWork(for:sizes:sizeLimit:); public func applyMetadata(_:generation:) -> [Int]
public func localMatches(_ query: LocalKeyQuery, from start: Int = 0, chunk: Int = localSearchChunk) -> LocalKeyMatches
```

`generation` changes whenever indices stop meaning what they meant (restart, removal); callers holding indices must pass
it back. `KeyIndexStatus`/`KeyIndexPhase`/`KeyPagingMode` drive the footer (`KeyIndexFooter.text`, `grouped`).
`KeyIndexError { code, message }` carries a shared code (`PROTOCOL_ERROR`, `PERMISSION_DENIED`, `SERVER_ERROR`, or the
data path's).

### Namespace tree, filters, display

| Type | Purpose |
| --- | --- |
| `NamespaceSeparator` | 1-4 bytes, `:` by default; `init?(_ bytes:)`, `init(profile:)` |
| `NamespaceFolderID`, `NamespaceChild`, `NamespaceEntry` | Folder handles (valid until a rebuild), a row (folder or key index), and a visible row's raw last segment + count + metadata. The tree itself (`NamespaceTree`) is internal: it stores no names, only offsets into `KeyIndex`'s arena; insertion is O(depth) |
| `KeyFilter` | Pattern (`Data`) + `KeyTypeFilter`; `scan(cursor:count:)` builds the `SCAN … MATCH … TYPE` operation. `.other` (module types) is filtered client side |
| `LocalKeyQuery` / `LocalKeyMatches` | Case-folded local search over loaded keys, chunked (`localSearchChunk = 131_072`) |
| `KeyDisplay` | `name(_:)` shows valid UTF-8 as is and escapes invalid bytes, control and bidi characters redis-cli style; `redisCliArgument(_:)`; `escaped(_:)`. Display only |
| `KeyType`, `KeyMetadata`, `RowExpiry`, `KeySize`, `KeyPresence` | Per-row type, TTL and size state |

### `RowMetadataLoader` (actor)

Loads `TYPE`/`PTTL` (and `MEMORY USAGE` when `showsSizes`) for visible rows through the index's data path, at most
every `interval = 100 ms`, `maximumRows = 256` per batch, `maximumSizes = 100`. Results are applied only when the index
`generation` still matches. Clock and sleep are injected. `TTLFormatter` and `KeySizeFormatter` format rows.

### `DatabaseList` (struct)

The database switcher: `load(service:context:databaseCount:mode:)` reads `INFO keyspace`; `parseKeyspace`,
`databaseCount(configReply:)`; `defaultCount = 16`, `maximumCount = 4_096`. Entries are `DatabaseEntry`.

## Value editing

### Editor contract (`KeyEditing.swift`)

```swift
public struct EditorRow: Sendable, Equatable, Identifiable { public var id: Data; public var value: Data }
public struct LoadedValue: Sendable, Equatable {
    public var rows: [EditorRow]
    public var watch: WatchGuard          // reads a save repeats under WATCH
    public var partial: PartialLoad?      // partial load: shown, not editable
    public var next: Data?                // "Load more" cursor; nil when complete
}
public struct EditorPage { public var rows: [EditorRow]; public var next: Data? }

public struct EditorBinding: Sendable {
    public var load: Load                 // (key, service, context) async throws(DataCommandError) -> LoadedValue
    public var writes: Writes             // (key, loaded, draft) -> [DataOperation]; empty when unchanged
    public var loadAll: Load?
    public var loadMore: LoadMore?
    public var saveGuard: Guard?          // per-save WatchGuard; nil uses LoadedValue.watch
    public var reread: Reread?            // re-read after a save or unknown outcome
    public var positional: Bool           // rows named by index (lists): no Overwrite on conflict
    public var editsValues: Bool          // false for set / sorted set / stream rows
    public static func editor(for type: KeyType) -> EditorBinding?
}
```

`EditorChanges.changedRows(loaded:draft:)`, `KeyHeader.load(key:type:service:context:)` (type, TTL, length, the one
metadata line) and `KeyDetails.load(key:memory:stream:service:context:)` (encoding, TTL, memory, stream summary; each
`notLoaded` / `loaded` / `unavailable`) complete the shell's data.

### Per-type editors (stateless enums exposing `binding`)

| Editor | Load | Save writes | Notes |
| --- | --- | --- | --- |
| `StringEditor` | `STRLEN`; ≤ 1 MiB `GET`, else `GETRANGE` first page (partial) | `SET … KEEPTTL` | `loadAll` refuses above the 64 MiB reply bound |
| `HashEditor` | `HLEN`; ≤ 1,000 `HGETALL`, else `HSCAN COUNT 500` pages | `HSET` per changed field + one `HDEL` | Guard per touched field (`HGET`); `add`/`rename`/`delete` draft helpers, `serverField` before overwriting an unloaded field |
| `ListEditor` | `LRANGE` pages of 500 from any index | `LSET` per changed item; a deletion is `LSET` to a unique sentinel + `LREM key 1 sentinel`; guarded by `LRANGE` of the touched span. `push`, `pop`, `insert` return `Action { writes, watch }` and run immediately | `positional`; `popNeedsConfirmation` on production |
| `SetEditor` | `SCARD`; ≤ 1,000 `SMEMBERS`, else `SSCAN` | `SADD` / `SREM` | `addOutcome` reports "already a member" |
| `SortedSetEditor` | `ZRANGE … BYSCORE` (probed) or `ZRANGEBYSCORE` pages, `Cursor` by score + skip | `ZADD [XX]`, `ZINCRBY`, `ZREM` | `search` via `ZSCAN MATCH`; `scoreText`/`parseScore` |
| `StreamEditor` | `XRANGE`/`XREVRANGE` pages, exclusive bounds when probed | `XADD` (`autoID = "*"`), `XDEL` | `problem(id:fields:)` validates before send; `StreamSummary` from `XINFO STREAM` |

All reads use the shared internal `EditorReads.read`, i.e. `service.execute(.operation(op), origin: .editor, ...)`.
A nil reply means the key went away (`"The key no longer exists."`).

### Key actions and new keys

```swift
public enum KeyActions {
    public static func rename(_ key: Data, to newKey: Data, overwrite: RenameOverwrite? = nil, service:, context:) async throws(DataCommandError) -> RenameOutcome
    public static func setTTL(_ key: Data, _ change: TTLChange, service:, context:, now:) async throws(DataCommandError) -> KeyExpiry
    public static func expiry(of key: Data, service:, context:, now:) async -> KeyExpiry
    public static func delete(_ key: Data, service:, context:) async throws(DataCommandError)
}
public enum NewKey {
    public static func problem(key: Data, value: Value, ttlMilliseconds: Int64?) -> String?
    public static func writes(key: Data, value: Value, ttlMilliseconds: Int64?) -> [DataOperation]
    public static func create(_ key: Data, _ value: Value, ttlMilliseconds: Int64? = nil, service:, context:) async throws(DataCommandError) -> Outcome
}
```

- `rename` sends `RENAMENX`; `RENAME` runs only with a `RenameOverwrite` token, which only a `.targetExists` outcome can
  create (internal memberwise init), for exactly those two names.
- `setTTL` refuses zero, negative or past expiries before sending (that would delete the key); `expiry` uses
  `PEXPIRETIME` when probed, else `PTTL`.
- Lost replies on rename/delete are settled by re-reading `TYPE`/`EXISTS`, never by re-sending.
- `NewKey.create` uses `SET NX [PX]` for strings and, for other types, `executeTransaction` guarded by `EXISTS == 0`.

### Viewing and export

| Type | Purpose |
| --- | --- |
| `ValueViewMode` | `text`, `json`, `hex`, `raw` (`isEditable` false for hex) |
| `ValueText`, `ValueRaw`, `ValueJSON`, `HexLayout`, `PrettyJSON` | Render and parse each view; `ValueJSON.maxDepth = 512`; `JSONSyntaxError` with line/column; `HexLayout.bytesPerLine = 16` |
| `ValueViewerState` | Per-value view state: `show(_:)`, `saveBlock` (why a save is refused, e.g. invalid JSON) |
| `ValueViewerMemory` | Remembered view per key pattern, `capacity = 1_000` (memory only) |
| `ValueExport` | `data`, `copyText`, `suggestedFileName`, `write(_:to:)` (atomic) for the loaded rows |

## Console

### `ConsoleSession` (actor)

One console: its own connection role, database and prompt; every command through the data path; replies printed like
redis-cli; streaming on a dedicated connection. Nothing it prints is logged or persisted.

```swift
public init(id: UUID = UUID(), service: DataCommandService, profile: SafetyProfile, database: Int, address: String? = nil, streamLimit: Int = ConsoleBuffer.lineLimit)
public var prompt: String; public private(set) var database: Int; public private(set) var isStreaming: Bool
public func run(_ arguments: [Data], confirmation: CommandConfirmation? = nil) async -> ConsoleOutcome
public func drainStream() -> ConsoleStreamDrain
public func stopStream() async; public func cancel() async; public func close() async
public static func errorText(_ error: DataCommandError) -> String
```

`run` asks `verdict` first. `confirmationRequired` returns `.needsConfirmation(request, warning:)` (with a
`ComplexityWarning` for `KEYS`/`FLUSHALL`); an allowed O(N) command returns `.needsGoAhead(warning)`; the UI re-runs
with a `CommandConfirmation(scope: .command(arguments), ...)`. A `cancel()` during a size read prevents the command from
being sent. `ConsoleOutcome`: `printed`, `needsConfirmation`, `needsGoAhead`, `streaming`.

### Console helpers

| Type | Purpose |
| --- | --- |
| `ConsoleTokenizer.arguments(_:)` | redis-cli line syntax to `[Data]` (quotes, `\xNN`); throws `ConsoleParseError` (`INVALID_PARAMS`) |
| `RedisCliFormatter.format(_:)` | `RESPValue` to redis-cli 7 TTY text; checked against goldens in `Tests/Fixtures/Console` |
| `ConsoleBuffer` | Scrollback capped at `lineLimit = 10_000` lines and `byteLimit = 16 MiB`; stream backlog keeps the newest 10,000 lines and counts `dropped` |
| `ConsoleHistory` / `ConsoleHistoryCursor` | In-memory history (`limit = 1_000`), search, up/down navigation; never persisted in v1 |
| `ConsoleMasking` | Masks secrets in `AUTH`, `HELLO … AUTH`, `ACL SETUSER`, `CONFIG SET` and `MIGRATE` as `••••••` in echoed lines (`maskedIndexes`, `display`, `displayUnparsed`) |
| `ConsoleCompleter` / `ConsoleCompletion` | Command and subcommand completion and the syntax hint from `CommandCatalog` |

## Bulk jobs

### `BulkDeleteJob` (actor)

Delete by pattern (FR-SF05, FR-SF06): `SCAN MATCH <pattern> COUNT 1000 [TYPE t]` and `UNLINK` batches of up to 1,000 keys
on the job's own `.job(id)` connection, origin `.bulk`, carrying a `.pattern` confirmation. Cancel is a flag, not task
cancellation, so an in-flight `UNLINK` finishes and its outcome stays known.

```swift
public init(pattern: Data, type: KeyTypeFilter? = nil, throttle: Int? = defaultThrottle, service: DataCommandService,
            profile: SafetyProfile, database: Int, clock: Clock = .continuous)
public static func refusal(pattern: Data, type: KeyTypeFilter?) -> String?      // empty, a pattern every key matches, or module type filter
public static func confirmation(for pattern: Data, database: Int) -> CommandConfirmation
public static func request(for pattern: Data, estimate: Int?, exact: Bool = false, profile: SafetyProfile, database: Int) -> TypedConfirmation
public func sample() async -> Sample                // up to 20 SCAN pages / 100 matches + DBSIZE, for the estimate
public func run(confirmation: CommandConfirmation, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Report
public func setThrottle(_ throttle: Int?)            // 1...100 batches/s, nil unthrottled
public nonisolated func cancel(); public nonisolated var isCancelled: Bool
public func close() async                            // closes the job connection
```

`Report.summary` always carries the caveat that keys created or renamed during the run may remain. `Progress.skipped` counts keys SCAN returned that `GlobPattern.matches` rejected (never sent); the summary names them and `Report.isComplete` is false while it is non-zero.

## App support

| Type | Kind | Purpose |
| --- | --- | --- |
| `KeelLog` | struct | `os_log` wrapper by `Category` (`connection`, `data`, `jobs`, `app`). Fields are `LogField`: `.code` (non-SCREAMING_SNAKE becomes `INVALID_CODE`), `.count`, `.serverKind`, `.serverText` (private, debug builds only). Errors are recorded in `DiagnosticsRecorder`. Sink and build are injectable |
| `DiagnosticsRecorder` / `DiagnosticsReport` | final class (lock) / Codable struct | Last 50 error codes and server kinds seen; `DiagnosticsReport.current(profileCount:)` exports `Keel Diagnostics.json` with no user data |
| `LaunchArguments` | struct | Strict parse of `--state-directory <abs>` and `--fixture`; unknown flags and single-dash spellings of Keel's flags (`-fixture`: `ParseError.singleDash`, with the suggested flag) throw `ParseError` (the app exits 64); other `-Key value` AppKit defaults are skipped |
| `LaunchMetrics` | enum | Writes first-sidebar-render seconds to `KEEL_LAUNCH_METRICS` for benchmarks |
| `KeelShortcut`, `KeelShortcutMap`, `KeelShortcutSettings` | enum / typealiases | Keel's menu actions over the vendored `ShortcutMap`/`KeyChord`/`ShortcutSettings` (`TrellisShared/KeyboardShortcuts.swift`) |
| `PaletteSearch` / `PaletteItem` / `RecentKeys` | enum / structs | Command-palette ranking (`limit = 50`) and in-memory recent keys (`limit = 20`, never persisted) |
| `Bundle.packagedResources(_:)` / `Bundle.keelCore` | extension | Resource lookup that tries `Contents/Resources/Keel_KeelCore.bundle` before `Bundle.module`; never use `Bundle.module` directly |
| `AppInstanceIdentity` | struct | `com.bearstouch.keel` vs `com.bearstouch.keel.dev`; selects the state folder |
| `AppVersion` | enum | `CFBundleShortVersionString`, falling back to `release` |
| `OwnerOnlyStorage` | enum (vendored) | Bounded owner-only reads and atomic 0600 writes used by `Persistence` |

## Adding a new command path / editor operation

1. **Add a `DataOperation` case** with `Data` parameters and its `arguments` mapping. Bytes go in unchanged; numbers are
   formatted with `String(_:)`. Never accept a pre-built command string.
2. **Check the classification.** The policy classifies from the catalog entry, not from the case name. Confirm the
   command is in `Resources/Commands/commands.json` (regenerate with `scripts/generate-command-catalog.py`, never edit
   by hand) and that `SafetyPolicy.classify` gives the class you expect: a read must be `read`/`neutral`, a write
   `write`. A multi-key delete becomes `destructive` and needs a `CommandConfirmation`; console-only classes are refused
   for `.editor`/`.browser`/`.bulk`. If the command exists only on some servers, add a `ServerCapability` with a
   read-only probe and branch on `service.supports(_:context:)`, with a fallback that works on Redis 6.0 and Valkey 7.2.
3. **Reads**: call `service.execute(.operation(op), origin: .editor, context:)` (inside an editor, `EditorReads.read`),
   and validate the reply shape; map nil to "key no longer exists" and server errors to the message the server sent.
   Bound what you read: check the length first (`.length`) and page above a limit, as `HashEditor`/`SetEditor` do.
4. **Writes that edit a loaded value** go through `executeTransaction(writes, unchanged: guard, context:)`, never
   `execute`. Build the `WatchGuard` from non-writing reads whose replies you captured at load time (or per save via
   `EditorBinding.saveGuard`, guarding only the touched elements). Handle `.conflict` (offer Reload / Overwrite unless
   `positional`) and `OUTCOME_UNKNOWN`/`TIMEOUT` by re-reading, never re-sending.
5. **Single-command actions** (rename, TTL, delete style) may use `execute`; on an unknown outcome re-read state
   (`TYPE`, `EXISTS`) to settle it, as `KeyActions` does. If an action needs the user's yes for a specific target, model
   it as a token only the refusal path can create (`RenameOverwrite`).
6. **A new type editor**: implement `load`/`writes` (+ `loadMore`, `saveGuard`, `reread` as needed), expose
   `static let binding = EditorBinding(...)`, and register it in `EditorBinding.editor(for:)`. The KeelUI
   `EditorSession` shell then handles drafts, changed rows, saves and conflicts.
7. **Tests**: assert the exact frames sent with `RecordingServer`/`RecordingTransport`, that a read-only profile sends
   nothing, that a conflict writes nothing, and that a lost reply is not re-sent. Add the case to the integration matrix
   if behavior differs across servers.

## Error codes

Codes KeelCore produces or passes through (`code` properties, `KeyIndexError.code`, `ConnectionErrorCategory.rawValue`).
Full semantics: [Errors](../architecture.md#errors).

| Code | Source in KeelCore | Meaning |
| --- | --- | --- |
| `READ_ONLY` | `SafetyVerdict.readOnly` | A possible write (write, destructive, script, admin, unknown) on a read-only or locked profile; nothing sent |
| `BLOCKED_COMMAND` | `SafetyVerdict.blocked` | Console-only command from another origin, or a forbidden command; nothing sent |
| `CONFIRMATION_REQUIRED` | `SafetyVerdict.confirmationRequired` | Destructive, admin or `KEYS` without a covering confirmation; nothing sent |
| `INVALID_PARAMS` | `DataCommandError.invalidRequest`, `ConsoleParseError` | Malformed request, missing console/job id, connection on another database, console parse error |
| `CONFLICT` | `DataCommandError.conflict`, `ProfileStoreError.conflict` | Guarded save found the key changed; stale profile revision |
| `OUTCOME_UNKNOWN` | `RedisError` via `.command` | Connection lost after a possible write was sent; re-read, never re-send |
| `TIMEOUT` | `RedisError`, `ConnectionFailure` | Connect, tunnel or command timed out |
| `NOT_CONNECTED` | `RedisError` | Connection not open or replaced mid-operation |
| `CONNECTION_FAILED` | `RedisError`, `ConnectionFailure` | Connection failed or dropped |
| `CANCELLED` | `RedisError`, `MultiKeyDelete.Failure` | Cancelled before the reply / between batches |
| `PROTOCOL_ERROR` | `RedisError`, `KeyIndexError` | Invalid RESP or an unexpected reply shape |
| `LIMIT_EXCEEDED` | `RedisError` | A reply exceeded a bound |
| `PERMISSION_DENIED` | `KeyIndexError`, `ConnectionErrorCategory` | ACL `NOPERM` |
| `SERVER_ERROR` | `KeyIndexError`, `MultiKeyDelete.Failure`, `ConnectionErrorCategory` | Any other server error reply |
| `UNSUPPORTED` | `CapabilityStatus.unavailableCode` | The server lacks a probed capability |
| `UNSUPPORTED_SERVER` | `ConnectionErrorCategory` | Below Redis 6.0; no tab opens |
| `DNS_FAILED`, `CONNECTION_REFUSED`, `TLS_UNTRUSTED`, `TLS_HOSTNAME_MISMATCH`, `TLS_HANDSHAKE_FAILED`, `NOT_TLS_EXPECTED`, `TLS_CA_UNAVAILABLE`, `TLS_CA_CHANGED`, `AUTH_FAILED`, `TUNNEL_FAILED`, `DB_OUT_OF_RANGE` | `ConnectionErrorCategory` | FR-CN10 connect failure categories |
| `INVALID_CODE` | `LogMessage.safeCode` | Placeholder logged when a non-SCREAMING_SNAKE string was passed as a code |

New codes are SCREAMING_SNAKE, shared across modules, and must be added to the architecture error table.

## Testing seams

| Seam | Injected through | Fakes / tests (`Tests/KeelCoreTests`) |
| --- | --- | --- |
| Transport / server | `ServerSession(open:)`, `RedisConnection(transport:)` | `DataPathFakes.swift`: `RecordingTransport` (records frames, scripted answers), `RecordingServer` (one transport per role, `opened`, `allCommands`, `session()`), `args(...)` helper |
| Connection creation | `ProfileSessionConnector(makeConnection:detector:settings:…)`, `ConnectionTester.MakeConnection` | `SessionConnectorTests`, `ConnectionTesterTests`, `*ErrorMappingTests` |
| Keychain (profile secrets) | `ProfileStore(persistence:secrets:makeID:)`, `any SecretStore` | `ProfileFakes.swift`: `FakeSecretStore`, `EventLog` (ordering of Keychain vs disk), `FailSwitch`, `ProfileFixture` |
| Keychain (TLS identities) | `TLSIdentityImporter(keychain:)` | `FakeTLSKeychain` in `IdentityImporterTests.swift` |
| CA file reads | `KnownCAStore(directory:readFile:)` | `KnownCATests`, `KnownCAReviewTests` |
| Filesystem and debounce | `Persistence(directory:debounce:sleep:beforeReplace:)`, `StateLocation.prepare(_:fileManager:)` | `PersistenceTests` (temp dirs, injected sleep, crash-before-rename) |
| Clocks | `RowMetadataLoader(now:sleep:)`, `BulkDeleteJob.Clock`, `KeyActions.setTTL(now:)`, `InfoOverview(report:now:)`, `DiagnosticsRecorder(now:)` | `RowMetadataLoaderTests`, `BulkDeleteJobTests` |
| Capability probes, catalog loads | `CapabilityProbe(probeKey:send:)`, `CommandCatalog.load(send:)`, `DatabaseList.probeCount(send:)` | `CapabilityProbeTests`, `CommandCatalogTests` |
| Logging | `KeelLog(_:build:recorder:sink:)` | `LoggingPolicyTests`; `SourceScanTests` greps sources for raw `print`/`NSLog` |
| UI-facing protocols | `SessionConnecting`, `ConnectionTesting` | Faked in `KeelUITests` |

Bundled resources are tested directly: `CommandCatalogTests` (catalog loads and matches the generator) and
`ServerDetectionTests` (INFO goldens per server). Performance tests (`*PerformanceTests`, `KeyIndexMemoryTests`) run on
in-memory fakes; large-data benchmarks run only with `KEEL_BENCH=1`. Never test against a user's servers.

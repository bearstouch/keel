# KeelRESP

`KeelRESP` is the engine-independent protocol layer: a streaming RESP2/RESP3 parser and encoder, the `RedisConnection`
actor over `NWConnection` (TCP, TLS, Unix socket), the connection handshake, pipelining, timeouts and bounded replies.
It has no UI, no persistence and no logging, and it never decides whether a command is allowed: every command reaches it
only through `DataCommandService` and `SafetyPolicy` in `KeelCore`. Keys and values are `Data` end to end.

Behavior: [Connections](../architecture.md#connections), [TLS](../architecture.md#tls), [Errors](../architecture.md#errors).

## Codec

### `RESPValue` (enum, Sendable, Equatable)

One decoded RESP2 or RESP3 value. Strings stay bytes; RESP2 nulls are kept distinct from the RESP3 null.

```swift
public enum RESPValue: Sendable {
    case simpleString(Data), error(Data), integer(Int64), bulkString(Data), array([RESPValue])
    case nullBulkString, nullArray          // RESP2 nulls
    case null, double(Double), boolean(Bool), bigNumber(String), blobError(Data)
    case verbatim(format: String, Data), map([RESPPair]), set([RESPValue]), push([RESPValue])
    indirect case attribute([RESPPair], RESPValue)
    public var isNull: Bool { get }
}
public struct RESPPair: Sendable, Equatable { public var key: RESPValue; public var value: RESPValue }
```

Equality treats two `NaN` doubles as equal.

### `RESPLimits` (struct, Sendable)

Bounds every buffer that grows with server data.

| Member | Standard |
| --- | --- |
| `maxReplyBytes` | 64 MiB |
| `maxDepth` | 128 |
| `maxElements` | 4,194,304 |

```swift
public static let standard: RESPLimits
public init(maxReplyBytes: Int, maxDepth: Int, maxElements: Int)
```

### `RESPParser` (struct, Sendable)

Incremental parser: feed bytes as they arrive, pull complete values. Returns `nil` while a frame is incomplete and
throws on malformed input or an exceeded limit.

```swift
public init(limits: RESPLimits = .standard)
public mutating func append(_ bytes: some Sequence<UInt8>)
public mutating func next() throws(RESPError) -> RESPValue?
```

### `RESPEncoder` (enum namespace)

```swift
public static func command(_ arguments: [Data]) -> Data          // array of bulk strings
public static func encode(_ value: RESPValue, maxDepth: Int = RESPLimits.standard.maxDepth) throws(RESPError) -> Data
```

### `RESPError`, `RESPViolation`, `RESPLimit`

```swift
public enum RESPError: Error, Equatable, Sendable {
    case protocolError(RESPViolation)   // code "PROTOCOL_ERROR"
    case limitExceeded(RESPLimit)       // code "LIMIT_EXCEEDED"
    public var code: String { get }
}
public enum RESPViolation: String { case unknownType, tlsRecord, invalidLength, invalidInteger, invalidDouble,
    invalidBoolean, invalidBigNumber, invalidVerbatim, invalidNull, invalidLineEnding, nestingTooDeep, streamedType, unframeable }
public enum RESPLimit: String { case replyBytes, elements }
```

`tlsRecord` flags a TLS record arriving on a plaintext connection; `streamedType` rejects RESP3 streamed aggregates.

## Connection

### `RedisConnection` (actor)

One connection to one server. Owns a `Transport` and a parser, matches replies to requests in order, applies timeouts
and reports interrupted writes as `OUTCOME_UNKNOWN` (re-read, never re-send). Callers open one per role
(`browser`, `console`, `stream`, `job`).

```swift
public enum State: Sendable, Equatable { case idle, connecting, ready, failed(RedisError), closed }
public struct Options: Sendable, Equatable {
    public var connectTimeout: Duration   // default 10 s
    public var commandTimeout: Duration   // default 30 s
    public var limits: RESPLimits
}
public private(set) var state: State
public nonisolated let options: Options
public nonisolated let pushes: AsyncStream<RESPValue>    // RESP3 out-of-band pushes
public nonisolated var tlsVerified: Bool? { get }         // nil = no TLS, false = verification skipped
public static let noTimeout: Duration

public init(transport: any Transport, options: Options = Options(),
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
public init(endpoint: RedisEndpoint, tls: TLSConfiguration? = nil, options: Options = Options())

public func connect() async throws(RedisError)
public func close()
public func send(_ arguments: [Data], mayWrite: Bool = true, timeout: Duration? = nil) async throws(RedisError) -> RESPValue
public func sendPipeline(_ commands: [[Data]], mayWrite: Bool = true, timeout: Duration? = nil) async throws(RedisError)
    -> [Result<RESPValue, RedisError>]
public func stream(_ arguments: [Data], buffer: Int = 10_000) throws(RedisError) -> AsyncStream<RESPValue>
```

| Call | Contract |
| --- | --- |
| `send` | Returns the reply, which may be a server error value. Throws `NOT_CONNECTED` and sends nothing unless `ready`. `mayWrite` (default `true`, fail closed) picks `OUTCOME_UNKNOWN` vs `CONNECTION_FAILED`/`CANCELLED` on interruption. A timeout fails with `TIMEOUT` and closes the connection. |
| `sendPipeline` | One write, replies in order, nothing interleaved: required for `MULTI ... EXEC` on a shared connection. Each command fails on its own. |
| `stream` | For `MONITOR` / `SUBSCRIBE`. No timeout; the connection accepts nothing else afterwards. Keeps the newest `buffer` values when the reader lags; `close()` is Stop. |

## Handshake

An extension on `RedisConnection` runs `HELLO` (falling back to `AUTH` when `HELLO` is unknown or answers `NOPROTO`),
`CLIENT SETNAME keel` and `SELECT`. On a `SELECT` failure it reads `CONFIG GET databases` to report the range.

```swift
public func handshake(_ options: HandshakeOptions) async throws(HandshakeError) -> HandshakeResult

public struct HandshakeOptions: Sendable, Equatable {   // description redacts the password
    public var username: String?, password: String?
    public var database: Int            // 0
    public var setName: Bool            // true
    public var protocolVersion: Int     // 3
    public var timeout: Duration        // 10 s
    public static let clientName = "keel"
}
public struct HandshakeResult: Sendable, Equatable { public var protocolVersion: Int; public var hello: RESPValue? }
public enum HandshakeStep: String, Sendable { case hello, auth, setName, select; public var command: String { get } }
public enum HandshakeError: Error, Equatable, Sendable {
    case connection(RedisError, step: HandshakeStep)
    case rejected(step: HandshakeStep, serverError: String)   // e.g. WRONGPASS, NOAUTH, NOPERM
    case databaseOutOfRange(index: Int, count: Int?)
}
```

## Transport

### `RedisEndpoint` (enum, Sendable)

```swift
case tcp(host: String, port: UInt16)
case unixSocket(path: String)
public static func bareHost(_ host: String) -> String   // "[::1]" -> "::1"; anything else unchanged
```

`host` may be a bracketed IPv6 literal as typed in a profile; `NetworkTransport` and `TLSConfiguration.expectedName`
use `bareHost`, so it connects to the address and is matched (never sent as SNI) as an IP.

### `Transport` (protocol, Sendable)

The byte stream under a connection. `send` is synchronous so the actor cannot interleave two callers between queuing
and writing; `receive` pulls one chunk at a time so a fast server cannot buffer unbounded data ahead of the parser.

```swift
public protocol Transport: Sendable {
    func connect() async throws(TransportError)
    func send(_ data: Data)                                   // failure surfaces on the next receive
    func receive() async throws(TransportError) -> Data       // never empty; .closed at end of stream
    func cancel()                                             // idempotent
    var tlsVerified: Bool? { get }                            // default nil
    func answersPlainRESP() async -> Bool                     // default false
}
```

### `NetworkTransport` (final class, Transport)

The `NWConnection` implementation for TCP, TLS and Unix sockets. After a failed TLS connect, `answersPlainRESP()` opens a
short plain connection and sends `PING` to tell "server is not using TLS" apart from other failures.

```swift
public convenience init(endpoint: RedisEndpoint, tls: TLSConfiguration? = nil)
public convenience init(endpoint: RedisEndpoint, parameters: NWParameters)
```

## TLS

### `TLSConfiguration` (struct, Sendable)

TLS 1.2 minimum, optional custom CA anchors, optional client identity, SNI from `serverName` or the endpoint host.
`skipVerification` exists only to be shown to the user in text (`tlsVerified == false`).

```swift
public static let minimumVersion: tls_protocol_version_t     // .TLSv12
public var serverName: String?
public var anchorCertificates: [Data]                         // DER
public var clientIdentity: TLSClientIdentity?
public var skipVerification: Bool
public static func certificates(fromPEM data: Data) throws(TLSBundleError) -> [Data]
public func expectedName(for endpoint: RedisEndpoint) -> String?
public func protocolSettings(for endpoint: RedisEndpoint) -> ProtocolSettings
public func makeOptions(for endpoint: RedisEndpoint, queue: DispatchQueue,
                        rejected: @escaping @Sendable (TLSTrustFailure) -> Void) -> NWProtocolTLS.Options
public func evaluate(_ trust: SecTrust, serverName: String?, at date: Date? = nil) -> TLSTrustFailure?
```

| Type | Kind | Purpose |
| --- | --- | --- |
| `TLSClientIdentity` | struct, `@unchecked Sendable` | Wraps a `SecIdentity` for mutual TLS. |
| `TLSTrustFailure` | enum, Error | `untrusted(issuer:customCA:)`, `hostnameMismatch(expected:certificateNames:)`, `noServerName`. |
| `TLSBundleError` | enum, Error | `noCertificates`, `unreadableCertificate`. |
| `PEMBlock` / `PEM` | struct / enum | `PEM.blocks(in:)` splits PEM text into labelled DER blocks. |

## Errors

### `RedisError` and `TransportError`

```swift
public enum RedisError: Error, Equatable, Sendable {
    case notConnected, connectionFailed(TransportError), connectionLost, timeout(TimeoutPhase)
    case outcomeUnknown, cancelled, codec(RESPError), unexpectedReply
    public var code: String { get }
}
public enum TransportError: Error, Equatable, Sendable {
    case posix(Int32), dns(Int32), tls(Int32), tlsRejected(TLSTrustFailure), plaintextServer, closed, cancelled, other
}
public enum TimeoutPhase: String, Sendable { case tunnel, connect, auth, command }
```

| Code | Produced by |
| --- | --- |
| `NOT_CONNECTED` | `send`/`sendPipeline`/`stream` before `ready` or after `stream`; nothing is sent. |
| `CONNECTION_FAILED` | `connectionFailed(_)`, `connectionLost`. |
| `TIMEOUT` | `timeout(phase)`; the connection is closed. |
| `OUTCOME_UNKNOWN` | A `mayWrite` command whose reply was lost. |
| `CANCELLED` | Task or connection cancelled. |
| `PROTOCOL_ERROR` | `codec(.protocolError)`, `unexpectedReply`. |
| `LIMIT_EXCEEDED` | `codec(.limitExceeded)`: reply over `RESPLimits`. |

Server error replies (`-ERR`, `WRONGPASS`, ...) are values (`.error`, `.blobError`), not thrown errors, except during
the handshake where they become `HandshakeError.rejected`.

## Testing seams

| Seam | Injected through | Fake |
| --- | --- | --- |
| Byte stream | `RedisConnection(transport:)` | `FakeTransport` (`Tests/KeelRESPTests/RedisConnectionFakes.swift`) records every frame sent, even after cancel, and plays the server by queuing reply chunks, drops and connect failures; `holdConnect` holds `connect()` open. `TLSFakeTransport` (`TLSConnectionReviewTests.swift`) adds `tlsVerified` and `answersPlainRESP`. |
| Time | `sleep:` closure on `RedisConnection.init` | Tests pass a controllable sleep to drive timeouts deterministically. |
| Trust | `TLSConfiguration.evaluate(_:serverName:at:)` | Evaluated against fixture certificates at a fixed date. |

Parser and encoder are pure value types tested with golden RESP frames (`Tests/Fixtures/`). Real servers are only used
by `KeelIntegrationTests` against pinned containers.

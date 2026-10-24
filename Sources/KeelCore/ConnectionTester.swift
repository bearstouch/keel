import Foundation
import KeelRESP
import KeelSSH

/// What a successful Test Connection found (FR-CN10): the server, its mode and the `PING` round trip.
public struct ConnectionTestResult: Sendable, Equatable {
    public var identity: ServerIdentity
    public var roundTrip: Duration
    /// Nil without TLS; false when **Skip verification** is on, which the line says in text (NFR-SC02).
    public var tlsVerified: Bool?

    public init(identity: ServerIdentity, roundTrip: Duration, tlsVerified: Bool? = nil) { self.identity = identity; self.roundTrip = roundTrip; self.tlsVerified = tlsVerified }

    /// The sheet's one line (FR-CN19): "✓ Connected · Valkey 8.1.1 · standalone · 2 ms".
    public var summary: String {
        var parts = ["✓ Connected", identity.displayName, identity.mode.rawValue, Self.milliseconds(roundTrip)]
        if tlsVerified == false { parts.append("TLS not verified") }
        return parts.joined(separator: " · ")
    }

    /// Whole milliseconds; a sub-millisecond loopback reply reads "<1 ms" rather than "0 ms".
    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let ms = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
        return ms < 1 ? "<1 ms" : "\(ms) ms"
    }
}

/// Runs Test Connection for the New Connection sheet. Injected so the sheet's model is tested without a server.
public protocol ConnectionTesting: Sendable {
    /// `profileID` is the profile being edited (nil for a new one); it only selects a saved client identity.
    func test(_ settings: ConnectionSettings, password: Data?, profileID: UUID?) async -> Result<ConnectionTestResult, ConnectionFailure>
}

/// A tunnel resolved from `TunnelSettings` (FR-CN05): ssh's configuration, the name failures show, and the saved
/// SSH password lookup for the launch, if any.
public struct ResolvedTunnel: Sendable {
    public var configuration: SSHTunnelConfiguration
    public var destination: String
    public var savedPassword: (@Sendable () async -> Data?)?

    public init(configuration: SSHTunnelConfiguration, destination: String, savedPassword: (@Sendable () async -> Data?)? = nil) {
        self.configuration = configuration; self.destination = destination; self.savedPassword = savedPassword
    }
}

/// FR-CN10: the full handshake — tunnel, TLS, `HELLO`/`AUTH`, `SELECT`, `PING`, `INFO server` — for settings that
/// may not be saved yet. Nothing is persisted: no profile, no Keychain item and no CA fingerprint record (the CA file
/// is read and checked, but first-use trust is recorded only by a real connect of a saved profile). The connection
/// is closed and the tunnel lease released whatever the outcome.
public struct ConnectionTester: ConnectionTesting {
    public typealias MakeConnection = @Sendable (RedisEndpoint, TLSConfiguration?, RedisConnection.Options) -> RedisConnection
    /// Resolves a saved SSH host (KEEL-018's library); nil means it is gone.
    public typealias ResolveSavedHost = @Sendable (UUID) async -> SavedHost?
    /// The saved SSH password lookup for one launch through a saved host (`HostLibrary.savedPassword(for:gate:)`).
    public typealias SavedHostPassword = @Sendable (SavedHost) -> (@Sendable () async -> Data?)?

    public static let defaultConnectTimeout = Duration.seconds(10)
    public static let defaultCommandTimeout = Duration.seconds(30)

    private let tunnels: TunnelManager?
    private let resolveSavedHost: ResolveSavedHost
    private let savedHostPassword: SavedHostPassword
    private let clientIdentity: @Sendable (UUID) -> TLSClientIdentity?
    private let readCAFile: @Sendable (String) throws(KnownCAError) -> Data
    private let makeConnection: MakeConnection
    private let detector: ServerDetector
    /// Settings → Advanced (FR-AP09), so Test uses the timeouts and `CLIENT SETNAME` a real connect would.
    private let advanced: @Sendable () -> AdvancedSettings

    public init(
        tunnels: TunnelManager? = nil, resolveSavedHost: @escaping ResolveSavedHost = { _ in nil }, savedHostPassword: @escaping SavedHostPassword = { _ in nil },
        clientIdentity: @escaping @Sendable (UUID) -> TLSClientIdentity? = { try? TLSIdentityImporter().clientIdentity(profileID: $0) },
        readCAFile: @escaping @Sendable (String) throws(KnownCAError) -> Data = { path throws(KnownCAError) in try CAFile.read(path) },
        makeConnection: @escaping MakeConnection = { RedisConnection(endpoint: $0, tls: $1, options: $2) }, detector: ServerDetector = ServerDetector(),
        advanced: @escaping @Sendable () -> AdvancedSettings = { AdvancedSettings() }
    ) {
        self.tunnels = tunnels; self.resolveSavedHost = resolveSavedHost; self.savedHostPassword = savedHostPassword; self.clientIdentity = clientIdentity; self.readCAFile = readCAFile
        self.makeConnection = makeConnection; self.detector = detector; self.advanced = advanced
    }

    public func test(_ settings: ConnectionSettings, password: Data?, profileID: UUID?) async -> Result<ConnectionTestResult, ConnectionFailure> {
        do throws(ConnectionFailure) { return .success(try await run(settings, password: password, profileID: profileID)) } catch { return .failure(error) }
    }

    private func run(_ settings: ConnectionSettings, password: Data?, profileID: UUID?) async throws(ConnectionFailure) -> ConnectionTestResult {
        let defaults = advanced()
        let connectTimeout = settings.connectTimeoutMilliseconds.map { Duration.milliseconds($0) } ?? defaults.connectTimeout
        let commandTimeout = settings.commandTimeoutMilliseconds.map { Duration.milliseconds($0) } ?? defaults.commandTimeout
        // The CA file is checked before anything is opened, so a missing file never starts ssh or a socket.
        let tls = try tlsConfiguration(settings, profileID: profileID)

        // Failures name the Redis host the user typed, not the tunnel's socket path.
        let shown = RedisEndpoint.tcp(host: settings.host, port: settings.port)
        var endpoint = shown
        var lease: TunnelLease?
        if let tunnel = settings.tunnel {
            let resolved = try await resolve(tunnel, settings: settings)
            guard let tunnels else { throw ConnectionFailure(tunnel: .shutDown, destination: resolved.destination) }
            // Its own lease id, so a Test never joins (or keeps alive) a saved profile's tunnel with other settings.
            do throws(TunnelError) {
                let acquired = try await tunnels.acquire(
                    profileID: UUID(), configuration: resolved.configuration, connectTimeout: connectTimeout, savedPassword: resolved.savedPassword)
                lease = acquired; endpoint = .unixSocket(path: acquired.socketPath)
            } catch { throw ConnectionFailure(tunnel: error, destination: resolved.destination) }
        }
        defer { if let lease, let tunnels { Task { await tunnels.release(lease) } } }

        let connection = makeConnection(endpoint, tls, RedisConnection.Options(connectTimeout: connectTimeout, commandTimeout: commandTimeout))
        defer { Task { await connection.close() } }
        do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(connecting: error, endpoint: shown, timeout: connectTimeout, tls: tls) }
        let options = HandshakeOptions(
            username: settings.username, password: password.map { String(decoding: $0, as: UTF8.self) }, database: settings.database, setName: defaults.setsClientName,
            timeout: connectTimeout)
        do throws(HandshakeError) { _ = try await connection.handshake(options) } catch {
            throw ConnectionFailure(handshake: error, endpoint: shown, options: options, tls: tls)
        }

        let clock = ContinuousClock()
        let start = clock.now
        _ = try await command(["PING"], on: connection, endpoint: shown, user: settings.username, timeout: connectTimeout)
        let roundTrip = clock.now - start
        let server = try await command(["INFO", "server"], on: connection, endpoint: shown, user: settings.username, timeout: connectTimeout)
        // `role` decides replica mode; an ACL user denied this section still gets a result from `INFO server`.
        let replication = try? await command(["INFO", "replication"], on: connection, endpoint: shown, user: settings.username, timeout: connectTimeout)
        guard let serverText = InfoFields.text(of: server) else { throw ConnectionFailure(category: .protocolError, message: "This port doesn't look like a Redis server.", suggestion: "Check the host and port.") }
        let identity = try detector.detect(info: serverText + "\n" + (replication.flatMap(InfoFields.text) ?? ""))
        return ConnectionTestResult(identity: identity, roundTrip: roundTrip, tlsVerified: connection.tlsVerified)
    }

    /// TLS for the test: the custom CA's certificates (read, never recorded), the saved client identity of the profile
    /// being edited, and SNI defaulting to the Redis host when tunneled (the socket path has no name to check).
    private func tlsConfiguration(_ settings: ConnectionSettings, profileID: UUID?) throws(ConnectionFailure) -> TLSConfiguration? {
        guard let tls = settings.tls else { return nil }
        var anchors: [Data] = []
        if let path = tls.caFile {
            do throws(KnownCAError) {
                let data = try readCAFile(path)
                do { anchors = try TLSConfiguration.certificates(fromPEM: data) } catch { throw KnownCAError.invalidBundle(path: path, error) }
            } catch { throw ConnectionFailure(caFile: error) }
        }
        let serverName = tls.serverName ?? (settings.tunnel == nil ? nil : settings.host)
        return TLSConfiguration(serverName: serverName, anchorCertificates: anchors, clientIdentity: profileID.flatMap(clientIdentity), skipVerification: tls.skipVerification)
    }

    func resolve(_ tunnel: TunnelSettings, settings: ConnectionSettings) async throws(ConnectionFailure) -> ResolvedTunnel {
        try await tunnel.resolved(settings: settings, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword)
    }

    /// One post-handshake command. An error reply is a failure of the test: `NOPERM` is `PERMISSION_DENIED`.
    private func command(_ words: [String], on connection: RedisConnection, endpoint: RedisEndpoint, user: String?, timeout: Duration) async throws(ConnectionFailure) -> RESPValue {
        let name = words.joined(separator: " ")
        let reply: RESPValue
        do throws(RedisError) { reply = try await connection.send(words.map { Data($0.utf8) }, mayWrite: false, timeout: timeout) } catch {
            throw ConnectionFailure(command: error, name: name, endpoint: endpoint, timeout: timeout)
        }
        switch reply {
        case .error(let text), .blobError(let text): throw ConnectionFailure(reply: String(decoding: text, as: UTF8.self), command: name, user: user)
        default: return reply
        }
    }
}

extension ConnectionFailure {
    /// A transport or protocol failure of a command sent after the handshake (Test Connection's `PING` / `INFO`).
    init(command error: RedisError, name: String, endpoint: RedisEndpoint, timeout: Duration) {
        switch error {
        case .timeout:
            self.init(
                category: .timeout, message: "The server didn't answer \(name) within \(timeout.shortText) (command).", suggestion: "Check the server's load, or raise the timeout.",
                phase: .command)
        case .codec, .unexpectedReply:
            self.init(category: .protocolError, message: "This port doesn't look like a Redis server.", suggestion: "Check the host and port.")
        default:
            self.init(category: .connectionFailed, message: "\(endpoint.displayName) closed the connection during \(name).", suggestion: "Check the server's logs and try again.")
        }
    }

    /// An error reply to a post-handshake command. Only the error code goes into the message; the full text, which
    /// for these commands never echoes an argument, goes into `serverError` for details.
    init(reply serverError: String, command: String, user: String?) {
        let code = serverError.prefix { $0 != " " }
        let user = user.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        switch code {
        case "NOPERM":
            self.init(
                category: .permissionDenied, message: "User “\(user)” isn't allowed to run \(command).", suggestion: "Grant \(command) to this user in the ACL.",
                serverError: serverError)
        case "NOAUTH":
            self.init(category: .authFailed, message: "This server requires a password.", suggestion: "Enter the password (and the username for an ACL user).", serverError: serverError)
        default:
            self.init(category: .serverError, message: "The server rejected \(command) (\(code)).", suggestion: "See the server's error in the details.", serverError: serverError)
        }
    }
}

extension TunnelSettings {
    /// ssh's configuration for this tunnel; a saved host that no longer exists fails as `TUNNEL_FAILED`. Shared by
    /// Test Connection and a real connect.
    func resolved(
        settings: ConnectionSettings, resolveSavedHost: ConnectionTester.ResolveSavedHost, savedHostPassword: ConnectionTester.SavedHostPassword
    ) async throws(ConnectionFailure) -> ResolvedTunnel {
        switch self {
        case .inline(let destination, let user, let port, let identityFile):
            let configuration = SSHTunnelConfiguration(destination: destination, user: user, port: port, identityFile: identityFile, redisHost: settings.host, redisPort: settings.port)
            return ResolvedTunnel(configuration: configuration, destination: destination)
        case .savedHost(let id):
            guard let host = await resolveSavedHost(id) else {
                throw ConnectionFailure(category: .tunnelFailed, message: "The saved SSH host of this connection no longer exists.", suggestion: "Choose another SSH host in the SSH tunnel settings.")
            }
            return ResolvedTunnel(
                configuration: SSHTunnelConfiguration(host: host, redisHost: settings.host, redisPort: settings.port), destination: host.destination,
                savedPassword: savedHostPassword(host))
        }
    }
}

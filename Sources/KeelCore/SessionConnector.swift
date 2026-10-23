import Foundation
import KeelRESP
import KeelSSH

/// A saved profile, connected (FR-CN15): the tab's session, the data path over it and what Keel learned about the
/// server when it connected.
public struct ConnectedServer: Sendable {
    public var session: ServerSession
    public var service: DataCommandService
    public var identity: ServerIdentity
    /// The server's `databases` when `CONFIG GET databases` was permitted (FR-KB08); nil offers db0–db15.
    public var databaseCount: Int?
    public var safety: SafetyProfile
    /// The profile's namespace separator (FR-KB03).
    public var separator: NamespaceSeparator
    /// Closes every connection of the session and releases its tunnel. Safe to call more than once.
    public var close: @Sendable () async -> Void

    public init(
        session: ServerSession, service: DataCommandService, identity: ServerIdentity, databaseCount: Int?, safety: SafetyProfile, separator: NamespaceSeparator = .default,
        close: @escaping @Sendable () async -> Void
    ) {
        self.session = session; self.service = service; self.identity = identity; self.databaseCount = databaseCount; self.safety = safety; self.separator = separator
        self.close = close
    }
}

/// Connects a tab's profile. Injected so the window and tab models are tested without a server.
public protocol SessionConnecting: Sendable {
    func connect(profileID: UUID, database: Int) async -> Result<ConnectedServer, ConnectionFailure>
}

/// The real connect of a saved profile (02 Architecture → Opening a connection): the Keychain password bound to the
/// profile's connection revision, TLS with the recorded CA (a changed CA file asks first), the SSH tunnel lease,
/// then a `ServerSession` whose every connection runs the handshake and `SELECT`. On the first (browser) connection it
/// identifies the server (`INFO server` / `INFO replication`, refusing servers below the minimum), loads the server's
/// command catalog and asks `CONFIG GET databases` — all best effort except identification. Any failure closes what
/// was opened and releases the tunnel.
public struct ProfileSessionConnector: SessionConnecting {
    public typealias MakeConnection = ConnectionTester.MakeConnection

    private let profiles: ProfileStore
    private let knownCA: KnownCAStore?
    private let tunnels: TunnelManager?
    private let resolveSavedHost: ConnectionTester.ResolveSavedHost
    private let savedHostPassword: ConnectionTester.SavedHostPassword
    private let clientIdentity: @Sendable (UUID) -> TLSClientIdentity?
    /// Asks the user whether a changed CA file is trusted (FR-CN04); false fails the connect with `TLS_CA_CHANGED`.
    private let confirmCAChange: @Sendable (CAChange) async -> Bool
    private let makeConnection: MakeConnection
    private let detector: ServerDetector

    public init(
        profiles: ProfileStore, knownCA: KnownCAStore? = nil, tunnels: TunnelManager? = nil, resolveSavedHost: @escaping ConnectionTester.ResolveSavedHost = { _ in nil },
        savedHostPassword: @escaping ConnectionTester.SavedHostPassword = { _ in nil },
        clientIdentity: @escaping @Sendable (UUID) -> TLSClientIdentity? = { try? TLSIdentityImporter().clientIdentity(profileID: $0) },
        confirmCAChange: @escaping @Sendable (CAChange) async -> Bool = { _ in false },
        makeConnection: @escaping MakeConnection = { RedisConnection(endpoint: $0, tls: $1, options: $2) }, detector: ServerDetector = ServerDetector()
    ) {
        self.profiles = profiles; self.knownCA = knownCA; self.tunnels = tunnels; self.resolveSavedHost = resolveSavedHost; self.savedHostPassword = savedHostPassword
        self.clientIdentity = clientIdentity; self.confirmCAChange = confirmCAChange; self.makeConnection = makeConnection; self.detector = detector
    }

    public func connect(profileID: UUID, database: Int) async -> Result<ConnectedServer, ConnectionFailure> {
        do throws(ConnectionFailure) { return .success(try await run(profileID: profileID, database: database)) } catch { return .failure(error) }
    }

    private func run(profileID: UUID, database: Int) async throws(ConnectionFailure) -> ConnectedServer {
        guard let profile = await profiles.profile(profileID) else {
            throw ConnectionFailure(category: .connectionFailed, message: "This connection no longer exists.", suggestion: "Close the tab, or create the connection again.")
        }
        let settings = profile.settings
        let safety = SafetyProfile(name: settings.name, readOnly: settings.readOnly)
        let connectTimeout = settings.connectTimeoutMilliseconds.map { Duration.milliseconds($0) } ?? ConnectionTester.defaultConnectTimeout
        let commandTimeout = settings.commandTimeoutMilliseconds.map { Duration.milliseconds($0) } ?? ConnectionTester.defaultCommandTimeout
        // Bound to the revision just read: an edit that changed the connection since never gets the old password.
        let password: Data?
        do throws(ProfileStoreError) { password = try await profiles.password(profileID: profileID, connectionRevision: profile.connectionRevision) } catch {
            throw ConnectionFailure(
                category: .authFailed, message: "Keel couldn't read this connection's saved password from the Keychain.", suggestion: "Unlock the Keychain, or enter the password again in the connection's settings.")
        }
        // The CA is checked before anything opens, so a missing or declined CA never starts ssh or a socket.
        let tls = try await tlsConfiguration(settings, profileID: profileID)

        let shown = RedisEndpoint.tcp(host: settings.host, port: settings.port)
        var endpoint = shown
        var lease: TunnelLease?
        if let tunnel = settings.tunnel {
            let resolved = try await tunnel.resolved(settings: settings, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword)
            guard let tunnels else { throw ConnectionFailure(tunnel: .shutDown, destination: resolved.destination) }
            // Keyed by the profile, so the tabs of one profile share its tunnel.
            do throws(TunnelError) {
                let acquired = try await tunnels.acquire(profileID: profileID, configuration: resolved.configuration, connectTimeout: connectTimeout, savedPassword: resolved.savedPassword)
                lease = acquired; endpoint = .unixSocket(path: acquired.socketPath)
            } catch { throw ConnectionFailure(tunnel: error, destination: resolved.destination) }
        }

        let makeConnection = makeConnection, target = endpoint
        let options = RedisConnection.Options(connectTimeout: connectTimeout, commandTimeout: commandTimeout)
        let username = settings.username, secret = password.map { String(decoding: $0, as: UTF8.self) }
        let closed = CloseOnce()
        let session = ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            // After Disconnect a browser task still running (a SCAN page, row metadata) must not open a new, unowned
            // connection; an open already under way when the session closes is closed by `ServerSession`.
            guard !closed.isClaimed else {
                throw ConnectionFailure(category: .connectionFailed, message: "This connection was closed.", suggestion: "Connect again.")
            }
            let connection = makeConnection(target, tls, options)
            do throws(RedisError) { try await connection.connect() } catch {
                await connection.close()
                throw ConnectionFailure(connecting: error, endpoint: shown, timeout: connectTimeout, tls: tls)
            }
            let handshake = HandshakeOptions(username: username, password: secret, database: database, timeout: connectTimeout)
            do throws(HandshakeError) { _ = try await connection.handshake(handshake) } catch {
                await connection.close()
                throw ConnectionFailure(handshake: error, endpoint: shown, options: handshake, tls: tls)
            }
            return connection
        }
        let tunnels = tunnels, heldLease = lease
        let close: @Sendable () async -> Void = {
            // A second call (disconnect, then the tab closing) must not release the profile's shared tunnel twice.
            guard closed.claim() else { return }
            await session.closeAll()
            if let heldLease, let tunnels { await tunnels.release(heldLease) }
        }
        do throws(ConnectionFailure) {
            let service = DataCommandService(session: session)
            let context = DataContext(profile: safety, database: database)
            let identity = try await identify(service, context, endpoint: shown, user: username, timeout: connectTimeout)
            // The server's catalog sharpens the policy for its own commands; a server that refuses COMMAND keeps the bundled one.
            try? await service.refreshCatalog(context: context)
            let count = await DatabaseList.probeCount { (arguments: [Data]) async throws(RedisError) -> RESPValue in
                let connection: RedisConnection
                do throws(ConnectionFailure) { connection = try await session.connection(for: .browser(database: database), database: database) } catch { throw .notConnected }
                return try await connection.send(arguments, mayWrite: false)
            }
            return ConnectedServer(
                session: session, service: service, identity: identity, databaseCount: count, safety: safety, separator: NamespaceSeparator(profile: settings.separator), close: close)
        } catch {
            await close()
            throw error
        }
    }

    /// `INFO server` (+ `INFO replication`, best effort) through the data path on the browser connection; opening
    /// that connection runs the handshake, so its failure is the connect's failure.
    private func identify(_ service: DataCommandService, _ context: DataContext, endpoint: RedisEndpoint, user: String?, timeout: Duration) async throws(ConnectionFailure)
        -> ServerIdentity
    {
        func info(_ section: String) async throws(ConnectionFailure) -> RESPValue {
            do throws(DataCommandError) {
                return try await service.execute(.operation(.info(section: Data(section.utf8))), origin: .browser, context: context).reply
            } catch {
                switch error {
                case .connection(let failure): throw failure
                case .command(let redisError): throw ConnectionFailure(command: redisError, name: "INFO \(section)", endpoint: endpoint, timeout: timeout)
                case .refused, .invalidRequest:
                    throw ConnectionFailure(category: .connectionFailed, message: "Keel couldn't ask the server what it is.", suggestion: "Try again.")
                }
            }
        }
        let server = try await info("server")
        if case .error(let text) = server { throw ConnectionFailure(reply: String(decoding: text, as: UTF8.self), command: "INFO server", user: user) }
        guard let serverText = InfoFields.text(of: server) else {
            throw ConnectionFailure(category: .protocolError, message: "This port doesn't look like a Redis server.", suggestion: "Check the host and port.")
        }
        // `role` decides replica mode; an ACL user denied this section still connects on `INFO server` alone.
        let replication = (try? await info("replication")).flatMap(InfoFields.text) ?? ""
        return try detector.detect(info: serverText + "\n" + replication)
    }

    /// TLS for a saved profile: the custom CA through the known-CA record (a changed file asks first), the profile's
    /// client identity, and SNI defaulting to the Redis host when tunneled.
    private func tlsConfiguration(_ settings: ConnectionSettings, profileID: UUID) async throws(ConnectionFailure) -> TLSConfiguration? {
        guard let tls = settings.tls else { return nil }
        var anchors: [Data] = []
        if let path = tls.caFile {
            do throws(KnownCAError) {
                if let knownCA {
                    anchors = try await knownCA.anchors(profile: profileID, caFile: path, confirm: confirmCAChange)
                } else {
                    let data = try CAFile.read(path)
                    do { anchors = try TLSConfiguration.certificates(fromPEM: data) } catch { throw KnownCAError.invalidBundle(path: path, error) }
                }
            } catch { throw ConnectionFailure(caFile: error) }
        }
        let serverName = tls.serverName ?? (settings.tunnel == nil ? nil : settings.host)
        return TLSConfiguration(serverName: serverName, anchorCertificates: anchors, clientIdentity: clientIdentity(profileID), skipVerification: tls.skipVerification)
    }
}

/// True for the first caller only.
private final class CloseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isClaimed: Bool { lock.withLock { done } }

    func claim() -> Bool {
        lock.withLock {
            let first = !done
            done = true
            return first
        }
    }
}

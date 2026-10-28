import Darwin
import Foundation
import KeelRESP
import KeelSSH

/// FR-CN10 connection error categories.
public enum ConnectionErrorCategory: String, Sendable, CaseIterable {
    case dnsFailed = "DNS_FAILED"
    case connectionRefused = "CONNECTION_REFUSED"
    case timeout = "TIMEOUT"
    case tlsUntrusted = "TLS_UNTRUSTED"
    case tlsHostnameMismatch = "TLS_HOSTNAME_MISMATCH"
    /// Protocol mismatch, a client certificate required or refused, or a server not speaking TLS.
    case tlsHandshakeFailed = "TLS_HANDSHAKE_FAILED"
    /// A TLS server reached without TLS.
    case notTLSExpected = "NOT_TLS_EXPECTED"
    /// The custom CA file is missing, unreadable or holds no usable certificate (FR-CN04).
    case tlsCAUnavailable = "TLS_CA_UNAVAILABLE"
    /// The custom CA file changed and the user didn't accept the new fingerprint (FR-CN04).
    case tlsCAChanged = "TLS_CA_CHANGED"
    case authFailed = "AUTH_FAILED"
    case permissionDenied = "PERMISSION_DENIED"
    /// ssh exited, the forward failed or the host key was declined (FR-CN05).
    case tunnelFailed = "TUNNEL_FAILED"
    case protocolError = "PROTOCOL_ERROR"
    case databaseOutOfRange = "DB_OUT_OF_RANGE"
    /// The connection dropped or the OS reported another error.
    case connectionFailed = "CONNECTION_FAILED"
    /// Any other error reply during the handshake.
    case serverError = "SERVER_ERROR"
    /// The server is older than Keel supports (Redis < 6.0, FR-CN11); no tab opens.
    case unsupportedServer = "UNSUPPORTED_SERVER"
}

/// Why opening a connection failed, in words the user can act on (FR-CN10). Messages name the host, user, phase or
/// command, never the password: every string is scrubbed of it, and server text loses echoed arguments.
public struct ConnectionFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var category: ConnectionErrorCategory
    public var message: String
    public var suggestion: String
    /// Set for `TIMEOUT`: which step ran out of time.
    public var phase: TimeoutPhase?
    /// The server's error reply, scrubbed, for details (05 API `details.serverError`).
    public var serverError: String?
    /// Set for `TUNNEL_FAILED` when ssh ran: its exit status and sanitized last stderr line.
    public var tunnelExit: TunnelExit?

    public init(category: ConnectionErrorCategory, message: String, suggestion: String, phase: TimeoutPhase? = nil, serverError: String? = nil, tunnelExit: TunnelExit? = nil) {
        self.category = category; self.message = message; self.suggestion = suggestion; self.phase = phase; self.serverError = serverError; self.tunnelExit = tunnelExit
    }

    public var description: String { "\(category.rawValue): \(message)" }

    /// A failure of `RedisConnection.connect()`: DNS, refused, timed out, TLS or another OS error. `tls` is the
    /// configuration the connection used, which decides the TLS wording (custom CA, client certificate).
    public init(connecting error: RedisError, endpoint: RedisEndpoint, timeout: Duration, tls: TLSConfiguration? = nil) {
        if case .connectionFailed(let transport) = error, let failure = Self.tls(transport, endpoint: endpoint, configuration: tls) { self = failure; return }
        let place = endpoint.displayName
        switch error {
        case .connectionFailed(.dns):
            self.init(category: .dnsFailed, message: "Couldn't find the host \(endpoint.host ?? place).", suggestion: "Check the host name, your VPN and your DNS settings.")
        case .connectionFailed(.posix(ECONNREFUSED)), .connectionFailed(.posix(ENOENT)):
            self.init(category: .connectionRefused, message: "Nothing is listening on \(place).", suggestion: "Check the port and that the server is running.")
        case .timeout, .connectionFailed(.posix(ETIMEDOUT)):
            self.init(
                category: .timeout, message: "Connecting to \(place) timed out after \(timeout.shortText) (\(tls == nil ? "TCP" : "TCP and TLS")).",
                suggestion: "Check the host, port and firewall, or raise the connect timeout.", phase: .connect)
        default:
            self.init(category: .connectionFailed, message: "Couldn't connect to \(place).", suggestion: "Check the host and port.")
        }
    }

    /// A server below the minimum version of its family (FR-CN11): "Keel requires Redis 6.0 or later; this server is Redis 5.0.7".
    public init(unsupported kind: ServerKind, version: ServerVersion?, minimum: ServerVersion) {
        let found = version.map { "this server is \(kind.displayName) \($0)" } ?? "this server doesn't report its \(kind.displayName) version"
        self.init(
            category: .unsupportedServer, message: "Keel requires \(kind.displayName) \(minimum) or later; \(found).",
            suggestion: "Upgrade the server to \(kind.displayName) \(minimum) or later, or connect to a newer one.")
    }

    /// A custom CA file that couldn't be used before connecting; no connection was attempted. Names the path (AC3).
    public init(caFile error: KnownCAError) {
        switch error {
        case .missing(let path):
            self.init(category: .tlsCAUnavailable, message: "The CA file “\(path)” doesn't exist.", suggestion: "Restore the file, or select the CA file again in the connection's TLS settings.")
        case .unreadable(let path, let code):
            self.init(
                category: .tlsCAUnavailable, message: "Couldn't read the CA file “\(path)”: \(Self.reason(code)).",
                suggestion: "Check that it is a readable PEM file of at most 4 MB, or select another CA file.")
        case .invalidBundle(let path, .noCertificates):
            self.init(category: .tlsCAUnavailable, message: "The CA file “\(path)” contains no certificate.", suggestion: "Select a PEM file with one or more “BEGIN CERTIFICATE” blocks.")
        case .invalidBundle(let path, .unreadableCertificate):
            self.init(category: .tlsCAUnavailable, message: "The CA file “\(path)” contains a certificate Keel can't read.", suggestion: "Check the file, or export the CA certificate again as PEM.")
        case .declined(let path):
            self.init(
                category: .tlsCAChanged, message: "The CA file “\(path)” changed and the new certificate wasn't accepted.",
                suggestion: "Connect again to review its fingerprint, or select the CA file you trust.")
        }
    }

    /// A tunnel that couldn't be opened (FR-CN05). `destination` is the SSH host as configured; no Redis connection was made.
    public init(tunnel error: TunnelError, destination: String) {
        switch error {
        case .exited(let exit):
            let status: String
            switch exit.status {
            case .exited(let code): status = "exited with status \(code)"
            case .signaled(let signal): status = "was stopped by signal \(signal)"
            }
            let detail = exit.lastErrorLine.map { ": \($0)" } ?? "."
            self.init(category: .tunnelFailed, message: "ssh to \(destination) \(status)\(detail)", suggestion: Self.tunnelSuggestion(exit.lastErrorLine, destination: destination), tunnelExit: exit)
        case .timeout(let timeout):
            self.init(
                category: .timeout, message: "The SSH tunnel through \(destination) wasn't ready within \(timeout.shortText) (tunnel).",
                suggestion: "Check that `ssh \(destination)` connects without a prompt, or raise the connect timeout.", phase: .tunnel)
        case .launchFailed(let code):
            self.init(category: .tunnelFailed, message: "Couldn't start \(SSHTunnelArguments.executable): \(Self.reason(code)).", suggestion: "Check that OpenSSH is installed at /usr/bin/ssh.")
        case .invalidArguments(let field):
            // The rejected text is never echoed: it may hold control characters or an injection attempt.
            self.init(category: .tunnelFailed, message: "The SSH tunnel settings aren't valid (\(Self.fieldName(field))).", suggestion: "Edit the connection's SSH tunnel settings.")
        case .runtimeDirectory:
            self.init(category: .tunnelFailed, message: "Couldn't create Keel's private folder for tunnel sockets.", suggestion: "Check the permissions of your temporary folder, then try again.")
        case .shutDown:
            self.init(category: .tunnelFailed, message: "The SSH tunnel was closed because Keel is quitting.", suggestion: "Open the connection again.")
        case .hostKeyNotAccepted(let exit):
            self.init(
                category: .tunnelFailed, message: "Host key not accepted for \(destination).",
                suggestion: "Connect again to review the fingerprint, or check the host's entry in ~/.ssh/known_hosts.", tunnelExit: exit)
        case .configuredForwards(let forwards):
            self.init(
                category: .tunnelFailed,
                message: "Your SSH configuration adds port forwards for \(destination) (\(forwards.joined(separator: "; "))), so Keel didn't start the tunnel: they would open TCP ports beside Keel's private socket.",
                suggestion: "Move LocalForward, RemoteForward and DynamicForward out of the Host or Match block that matches \(destination) in ~/.ssh/config (or Host *), or use an alias without them.")
        }
    }

    private static func tunnelSuggestion(_ line: String?, destination: String) -> String {
        let text = line?.lowercased() ?? ""
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return "Check the SSH server's host key in ~/.ssh/known_hosts."
        }
        if text.contains("permission denied") { return "Check the SSH user, key or saved password for \(destination)." }
        if text.contains("forward") || text.contains("open failed") || text.contains("connect failed") {
            return "Check the Redis host and port as seen from the SSH server."
        }
        if text.contains("could not resolve") { return "Check the SSH host name, your VPN and your DNS settings." }
        return "Check that `ssh \(destination)` works in Terminal."
    }

    private static func fieldName(_ error: SSHTunnelArgumentError) -> String {
        switch error {
        case .invalidDestination: return "SSH host"
        case .invalidUser: return "SSH user"
        case .invalidIdentityFile: return "identity file"
        case .invalidPort: return "SSH port"
        case .invalidRedisHost: return "Redis host"
        case .invalidRedisPort: return "Redis port"
        }
    }

    private static func reason(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "permission denied"
        case EISDIR: return "it is a folder"
        case EFTYPE: return "it isn't a regular file"
        case EFBIG: return "it is larger than 4 MB"
        default: return String(cString: strerror(code)).lowercased()
        }
    }

    /// A failure of `RedisConnection.handshake(_:)`. `options` supplies the user and timeout for the message and
    /// the password to scrub; the password itself is never stored. `tls` is the connection's TLS configuration: a
    /// TLS 1.3 server refuses a client certificate only once the first command is sent.
    public init(handshake error: HandshakeError, endpoint: RedisEndpoint, options: HandshakeOptions, tls: TLSConfiguration? = nil) {
        if case .connection(.connectionFailed(let transport), _) = error, let failure = Self.tls(transport, endpoint: endpoint, configuration: tls) { self = failure; return }
        let user = options.username.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        switch error {
        case .connection(.codec(.protocolError(.tlsRecord)), _) where tls == nil:
            self.init(category: .notTLSExpected, message: "\(endpoint.displayName) answered with TLS.", suggestion: "Turn on TLS for this connection.")
        case .connection(.timeout, let step):
            self.init(
                category: .timeout, message: "The server didn't answer \(step.command) within \(options.timeout.shortText) (AUTH).", suggestion: "Check that this port serves Redis, or raise the timeout.", phase: .auth)
        case .connection(.codec, _), .connection(.unexpectedReply, _):
            self.init(category: .protocolError, message: "This port doesn't look like a Redis server.", suggestion: "Check the host and port.")
        case .connection(_, let step):
            // With TLS already on, "turn on TLS" is wrong: a TLS 1.3 server that refuses the client certificate
            // can also just close the stream.
            self.init(
                category: .connectionFailed, message: "\(endpoint.displayName) closed the connection during \(step.command).",
                suggestion: tls == nil ? "If the server requires TLS, turn on TLS." : "The server may require a client certificate; check it and the server's TLS settings.")
        case .databaseOutOfRange(let index, let count?):
            let last = max(count - 1, 0)
            self.init(category: .databaseOutOfRange, message: "Database \(index) doesn't exist; this server has \(count) databases (0–\(last)).", suggestion: "Choose a database from 0 to \(last).")
        case .databaseOutOfRange(let index, nil):
            self.init(category: .databaseOutOfRange, message: "Database \(index) doesn't exist on this server.", suggestion: "Choose a lower database number.")
        case .rejected(let step, let serverError):
            self = Self.rejected(step, serverError, user: user)
        }
        if let password = options.password, !password.isEmpty {
            message = message.replacingOccurrences(of: password, with: "••••••")
            serverError = serverError?.replacingOccurrences(of: password, with: "••••••")
        }
    }

    /// The TLS categories: Keel's verify block refusing the chain, a handshake status from Network, or a plain RESP
    /// answer after TLS failed. Nil for transport errors that aren't about TLS.
    private static func tls(_ error: TransportError, endpoint: RedisEndpoint, configuration: TLSConfiguration?) -> ConnectionFailure? {
        let place = endpoint.displayName
        switch error {
        case .tlsRejected(.untrusted(let issuer, let customCA)):
            return .init(
                category: .tlsUntrusted, message: "The certificate of \(place) isn't trusted: it was issued by “\(issuer)”.",
                suggestion: customCA ? "The selected CA didn't issue this certificate; select the CA that did." : "Select the CA that issued it as this connection's custom CA.")
        case .tlsRejected(.hostnameMismatch(let expected, let names)):
            let covered = names.isEmpty ? "no names" : names.map { "“\($0)”" }.joined(separator: ", ")
            return .init(
                category: .tlsHostnameMismatch, message: "The certificate doesn't match “\(expected)”; it is for \(covered).",
                suggestion: names.first.map { "Set the TLS server name (SNI) to “\($0)”." } ?? "Set the TLS server name (SNI) to the certificate's name.")
        case .tlsRejected(.noServerName):
            return .init(category: .tlsHostnameMismatch, message: "There is no server name to check the certificate of \(place) against.", suggestion: "Set the TLS server name (SNI).")
        case .plaintextServer:
            return .init(category: .tlsHandshakeFailed, message: "Server may not be using TLS: \(place) answered in plain text.", suggestion: "Turn off TLS for this connection.")
        case .tls(let status):
            return tlsHandshake(status, place: place, hasIdentity: configuration?.clientIdentity != nil)
        default:
            return nil
        }
    }

    /// Network's `errSSL…` statuses, grouped by what the user can do about them (SecureTransport.h).
    private static func tlsHandshake(_ status: Int32, place: String, hasIdentity: Bool) -> ConnectionFailure {
        let code = "(\(status))"
        switch status {
        // The peer refused or wanted a client certificate: certificate required/unknown/bad, unknown CA, revoked,
        // expired, access denied.
        case -9863, -9829, -9825, -9826, -9827, -9828, -9831, -9832:
            guard hasIdentity else {
                return .init(category: .tlsHandshakeFailed, message: "\(place) requires a client certificate \(code).", suggestion: "Choose a client certificate for this connection.")
            }
            return .init(
                category: .tlsHandshakeFailed, message: "\(place) rejected the client certificate \(code).", suggestion: "Check that the certificate is valid and issued by a CA the server trusts.")
        // A plain handshake failure alert: often a missing client certificate on TLS 1.2, else no shared cipher.
        case -9824:
            return .init(
                category: .tlsHandshakeFailed, message: "\(place) ended the TLS handshake \(code).",
                suggestion: hasIdentity ? "Check the client certificate and the server's TLS settings." : "The server may require a client certificate; choose one for this connection.")
        // Protocol version or cipher negotiation.
        case -9836, -9801, -9837:
            return .init(category: .tlsHandshakeFailed, message: "\(place) and Keel share no TLS version or cipher \(code).", suggestion: "Keel requires TLS 1.2 or later; enable it on the server.")
        default:
            return .init(category: .tlsHandshakeFailed, message: "The TLS handshake with \(place) failed \(code).", suggestion: "Check that this port serves TLS and that the server's TLS settings are valid.")
        }
    }

    /// Classifies a server error reply by its code: `WRONGPASS`, `NOAUTH`, `NOPERM`, the older `ERR invalid
    /// password`, and AUTH sent to a server without a password.
    private static func rejected(_ step: HandshakeStep, _ serverError: String, user: String) -> ConnectionFailure {
        let code = serverError.prefix { $0 != " " }
        let text = serverError.lowercased()
        switch code {
        case "WRONGPASS":
            return .init(category: .authFailed, message: "Authentication failed for user “\(user)”: wrong password, or the user is disabled.", suggestion: "Check the username and password.", serverError: serverError)
        case "NOAUTH":
            return .init(category: .authFailed, message: "This server requires a password.", suggestion: "Enter the password (and the username for an ACL user).", serverError: serverError)
        case "NOPERM":
            return .init(
                category: .permissionDenied, message: "User “\(user)” isn't allowed to run \(step.command).",
                suggestion: step == .setName ? "Turn off CLIENT SETNAME in Settings → Advanced, or grant the command in the ACL." : "Grant \(step.command) to this user in the ACL.", serverError: serverError)
        case "ERR" where text.contains("invalid password") || text.contains("invalid username-password"):
            return .init(category: .authFailed, message: "Authentication failed for user “\(user)”: wrong password.", suggestion: "Check the username and password.", serverError: serverError)
        case "ERR" where text.contains("without any password configured") || text.contains("no password is set"):
            return .init(category: .authFailed, message: "This server has no password set for user “\(user)”.", suggestion: "Clear the password, or check that this is the right server.", serverError: serverError)
        default:
            return .init(category: .serverError, message: "The server rejected \(step.command) (\(code)).", suggestion: "See the server's error in the details.", serverError: serverError)
        }
    }
}

extension RedisEndpoint {
    /// `host:port` (IPv6 hosts in brackets) or the socket path.
    var displayName: String {
        switch self {
        case .tcp(let host, let port): return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .unixSocket(let path): return path
        }
    }

    var host: String? {
        if case .tcp(let host, _) = self { return host }
        return nil
    }
}

extension Duration {
    /// "10 s" or "250 ms".
    var shortText: String {
        let (seconds, attoseconds) = components
        if attoseconds == 0 { return "\(seconds) s" }
        return "\(seconds * 1_000 + attoseconds / 1_000_000_000_000_000) ms"
    }
}

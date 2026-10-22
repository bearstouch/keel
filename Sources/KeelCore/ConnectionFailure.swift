import Darwin
import Foundation
import KeelRESP

/// FR-CN10 connection error categories. TLS and tunnel categories join with their stories.
public enum ConnectionErrorCategory: String, Sendable, CaseIterable {
    case dnsFailed = "DNS_FAILED"
    case connectionRefused = "CONNECTION_REFUSED"
    case timeout = "TIMEOUT"
    case authFailed = "AUTH_FAILED"
    case permissionDenied = "PERMISSION_DENIED"
    case protocolError = "PROTOCOL_ERROR"
    case databaseOutOfRange = "DB_OUT_OF_RANGE"
    /// The connection dropped or the OS reported another error.
    case connectionFailed = "CONNECTION_FAILED"
    /// Any other error reply during the handshake.
    case serverError = "SERVER_ERROR"
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

    public init(category: ConnectionErrorCategory, message: String, suggestion: String, phase: TimeoutPhase? = nil, serverError: String? = nil) {
        self.category = category; self.message = message; self.suggestion = suggestion; self.phase = phase; self.serverError = serverError
    }

    public var description: String { "\(category.rawValue): \(message)" }

    /// A failure of `RedisConnection.connect()`: DNS, refused, timed out or another OS error.
    public init(connecting error: RedisError, endpoint: RedisEndpoint, timeout: Duration) {
        let place = endpoint.displayName
        switch error {
        case .connectionFailed(.dns):
            self.init(category: .dnsFailed, message: "Couldn't find the host \(endpoint.host ?? place).", suggestion: "Check the host name, your VPN and your DNS settings.")
        case .connectionFailed(.posix(ECONNREFUSED)), .connectionFailed(.posix(ENOENT)):
            self.init(category: .connectionRefused, message: "Nothing is listening on \(place).", suggestion: "Check the port and that the server is running.")
        case .timeout, .connectionFailed(.posix(ETIMEDOUT)):
            self.init(category: .timeout, message: "Connecting to \(place) timed out after \(timeout.shortText) (TCP).", suggestion: "Check the host, port and firewall, or raise the connect timeout.", phase: .connect)
        default:
            self.init(category: .connectionFailed, message: "Couldn't connect to \(place).", suggestion: "Check the host and port.")
        }
    }

    /// A failure of `RedisConnection.handshake(_:)`. `options` supplies the user and timeout for the message and
    /// the password to scrub; the password itself is never stored.
    public init(handshake error: HandshakeError, endpoint: RedisEndpoint, options: HandshakeOptions) {
        let user = options.username.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        switch error {
        case .connection(.timeout, let step):
            self.init(
                category: .timeout, message: "The server didn't answer \(step.command) within \(options.timeout.shortText) (AUTH).", suggestion: "Check that this port serves Redis, or raise the timeout.", phase: .auth)
        case .connection(.codec, _), .connection(.unexpectedReply, _):
            self.init(category: .protocolError, message: "This port doesn't look like a Redis server.", suggestion: "Check the host and port.")
        case .connection(_, let step):
            self.init(category: .connectionFailed, message: "\(endpoint.displayName) closed the connection during \(step.command).", suggestion: "If the server requires TLS, turn on TLS.")
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
                suggestion: step == .setName ? "Turn off CLIENT SETNAME for this connection, or grant the command in the ACL." : "Grant \(step.command) to this user in the ACL.", serverError: serverError)
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

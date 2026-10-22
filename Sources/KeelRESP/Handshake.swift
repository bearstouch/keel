import Foundation

/// What the handshake sends once the socket is open (02 Architecture → Connections, INT-03).
public struct HandshakeOptions: Sendable, Equatable {
    /// ACL user; nil or empty means `default` (`HELLO … AUTH default <pass>`, or one-argument `AUTH <pass>`).
    public var username: String?
    /// Never logged, printed or put in an error. With neither a username nor a password (nil or empty, as an empty
    /// form field gives), no AUTH is sent, so a protected server answers `NOAUTH`, not `WRONGPASS`.
    public var password: String?
    /// `SELECT` target; db 0 is every new connection's default, so it sends no `SELECT`.
    public var database: Int
    /// `CLIENT SETNAME keel` (NFR-PV04): on by default, off per profile.
    public var setName: Bool
    /// RESP version asked for with `HELLO`: 3 for browser and agent connections, 2 for the console.
    public var protocolVersion: Int
    /// Limit for each handshake command; exceeding it fails with `TIMEOUT` in the AUTH phase.
    public var timeout: Duration

    public static let clientName = "keel"

    public init(username: String? = nil, password: String? = nil, database: Int = 0, setName: Bool = true, protocolVersion: Int = 3, timeout: Duration = .seconds(10)) {
        self.username = username; self.password = password; self.database = database
        self.setName = setName; self.protocolVersion = protocolVersion; self.timeout = timeout
    }

    var user: String? { username.flatMap { $0.isEmpty ? nil : $0 } }
    var authenticates: Bool { user != nil || !(password ?? "").isEmpty }
}

// Keeps the password out of `print`, string interpolation and test failure output.
extension HandshakeOptions: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "HandshakeOptions(username: \(user ?? "default"), password: \(password == nil ? "none" : "••••••"), database: \(database), setName: \(setName), protocolVersion: \(protocolVersion))"
    }
    public var debugDescription: String { description }
}

// `dump`, the debugger and test reflection read the mirror, not `description`.
extension HandshakeOptions: CustomReflectable {
    public var customMirror: Mirror { Mirror(self, children: ["description": description], displayStyle: .struct) }
}

public struct HandshakeResult: Sendable, Equatable {
    /// `protocolVersion` when `HELLO` succeeded; 2 on the `AUTH` fallback.
    public var protocolVersion: Int
    /// The `HELLO` reply (server, version, proto, id, mode, role) for detection (INT-02); nil on the fallback.
    public var hello: RESPValue?

    public init(protocolVersion: Int, hello: RESPValue?) { self.protocolVersion = protocolVersion; self.hello = hello }
}

public enum HandshakeStep: String, Sendable {
    case hello, auth, setName, select

    /// The command as shown to the user, e.g. "PERMISSION_DENIED: user can't run SELECT".
    public var command: String {
        switch self {
        case .hello: return "HELLO"
        case .auth: return "AUTH"
        case .setName: return "CLIENT SETNAME"
        case .select: return "SELECT"
        }
    }
}

public enum HandshakeError: Error, Equatable, Sendable {
    /// The connection failed, sent bytes that aren't RESP, or didn't answer `step` in time (`.timeout(.auth)`).
    case connection(RedisError, step: HandshakeStep)
    /// The server answered `step` with an error reply. The text has the password and any echoed arguments removed.
    case rejected(step: HandshakeStep, serverError: String)
    /// `SELECT index` failed; `count` comes from `CONFIG GET databases` when the user may run it.
    case databaseOutOfRange(index: Int, count: Int?)
}

extension RedisConnection {
    /// Authenticates, names the client and selects the database: `HELLO <proto> [AUTH user pass] [SETNAME keel]`,
    /// or, when the server doesn't know `HELLO` or the protocol version, `AUTH` + `CLIENT SETNAME` on RESP2; then
    /// `SELECT db`. Stops at the first failure, which the caller maps to an FR-CN10 category; the connection is then
    /// unusable and should be closed.
    public func handshake(_ options: HandshakeOptions) async throws(HandshakeError) -> HandshakeResult {
        var hello = ["HELLO", String(options.protocolVersion)]
        if options.authenticates { hello += ["AUTH", options.user ?? "default", options.password ?? ""] }
        if options.setName { hello += ["SETNAME", HandshakeOptions.clientName] }
        let reply = try await handshakeCommand(.hello, hello, options)
        let result: HandshakeResult
        if let error = Self.serverError(reply) {
            // Only "HELLO or this protocol isn't available" falls back; an auth or ACL error is the real answer.
            guard Self.isUnknownCommand(error) || Self.errorCode(error) == "NOPROTO" else {
                throw .rejected(step: .hello, serverError: Self.redacted(error, options.password))
            }
            try await legacyHandshake(options)
            result = HandshakeResult(protocolVersion: 2, hello: nil)
        } else {
            result = HandshakeResult(protocolVersion: options.protocolVersion, hello: reply)
        }
        if options.database != 0 { try await select(options) }
        return result
    }

    /// The pre-`HELLO` path: one- or two-argument `AUTH`, then `CLIENT SETNAME`.
    private func legacyHandshake(_ options: HandshakeOptions) async throws(HandshakeError) {
        if options.authenticates {
            let auth = options.user.map { ["AUTH", $0, options.password ?? ""] } ?? ["AUTH", options.password ?? ""]
            try await expectOK(.auth, auth, options)
        }
        if options.setName { try await expectOK(.setName, ["CLIENT", "SETNAME", HandshakeOptions.clientName], options) }
    }

    private func select(_ options: HandshakeOptions) async throws(HandshakeError) {
        let reply = try await handshakeCommand(.select, ["SELECT", String(options.database)], options)
        guard let error = Self.serverError(reply) else { return }
        // Redis and Valkey say "DB index is out of range"; a negative index is "invalid DB index" on some servers.
        let text = String(decoding: error, as: UTF8.self).lowercased()
        guard Self.errorCode(error) == "ERR", text.contains("out of range") || text.contains("invalid db index") else {
            throw .rejected(step: .select, serverError: Self.redacted(error, options.password))
        }
        throw .databaseOutOfRange(index: options.database, count: await databaseCount(options))
    }

    /// `CONFIG GET databases`, best effort: nil when the ACL forbids it or the reply is odd.
    private func databaseCount(_ options: HandshakeOptions) async -> Int? {
        guard let reply = try? await send(["CONFIG", "GET", "databases"].map { Data($0.utf8) }, mayWrite: false, timeout: options.timeout) else { return nil }
        let value: RESPValue?
        switch reply {
        case .array(let items) where items.count == 2: value = items[1]  // RESP2: name, value
        case .map(let pairs) where pairs.count == 1: value = pairs[0].value  // RESP3
        default: value = nil
        }
        guard case .bulkString(let bytes)? = value else { return nil }
        return Int(String(decoding: bytes, as: UTF8.self))
    }

    private func expectOK(_ step: HandshakeStep, _ arguments: [String], _ options: HandshakeOptions) async throws(HandshakeError) {
        let reply = try await handshakeCommand(step, arguments, options)
        if let error = Self.serverError(reply) { throw .rejected(step: step, serverError: Self.redacted(error, options.password)) }
    }

    /// Sends one handshake command. They are marked read-only so an interruption or a non-RESP reply reaches the
    /// caller as itself, not `OUTCOME_UNKNOWN`: none of them changes data, and a new connection re-runs them all.
    private func handshakeCommand(_ step: HandshakeStep, _ arguments: [String], _ options: HandshakeOptions) async throws(HandshakeError) -> RESPValue {
        do {
            return try await send(arguments.map { Data($0.utf8) }, mayWrite: false, timeout: options.timeout)
        } catch .timeout {
            throw .connection(.timeout(.auth), step: step)
        } catch {
            // A peer that talks first (an SSH or SMTP banner) breaks the stream before HELLO is sent; report why.
            if error == .notConnected, case .failed(let reason) = state { throw .connection(reason, step: step) }
            throw .connection(error, step: step)
        }
    }

    // MARK: - Server error text

    static func serverError(_ reply: RESPValue) -> Data? {
        switch reply {
        case .error(let text), .blobError(let text): return text
        default: return nil
        }
    }

    /// The leading uppercase word of an error reply (`ERR`, `WRONGPASS`, `NOAUTH`, `NOPERM`, `NOPROTO`).
    static func errorCode(_ error: Data) -> String {
        String(decoding: error.prefix { $0 != UInt8(ascii: " ") }, as: UTF8.self)
    }

    static func isUnknownCommand(_ error: Data) -> Bool {
        errorCode(error) == "ERR" && String(decoding: error, as: UTF8.self).lowercased().contains("unknown command")
    }

    /// Server text safe to keep: Redis 6.2+ echoes arguments ("…, with args beginning with: '3' 'AUTH' 'default'
    /// 'secret'"), so that tail is cut, and any remaining copy of the password is replaced.
    static func redacted(_ error: Data, _ password: String?) -> String {
        var text = String(decoding: error, as: UTF8.self)
        if let echo = text.range(of: ", with args beginning with") { text = String(text[..<echo.lowerBound]) }
        if let password, !password.isEmpty { text = text.replacingOccurrences(of: password, with: "••••••") }
        return text
    }
}

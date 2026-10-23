import Foundation

/// Why a pasted connection URL was refused (FR-CN08). The New Connection sheet shows `message` inline and changes
/// nothing.
public enum RedisURLError: Error, Equatable, Sendable {
    case notAURL
    case unsupportedScheme
    case invalidEncoding
    case invalidUserinfo
    case invalidHost
    case invalidPort
    case invalidDatabase

    public var message: String {
        switch self {
        case .notAURL: "Not a connection URL. Use redis://[user[:password]@]host[:port][/db]."
        case .unsupportedScheme: "Only redis:// and rediss:// URLs are supported."
        case .invalidEncoding: "The URL has an invalid percent-encoding."
        case .invalidUserinfo: "The user name in the URL is invalid."
        case .invalidHost: "The host in the URL is missing or invalid."
        case .invalidPort: "The port must be a number from 1 to 65535."
        case .invalidDatabase: "The database must be a number from 0 to 65535."
        }
    }
}

/// A parsed `redis://` / `rediss://` URL (INT-04). It only fills editor fields: it is never persisted, and the password
/// goes to the Keychain through `ProfileStore` when the profile is saved.
public struct RedisURL: Equatable, Sendable {
    public var tls: Bool
    public var username: String?
    /// Percent-decoded bytes; nil when the URL carries no password.
    public var password: Data?
    /// Bare host: IPv6 literals are stored without brackets, as `NWEndpoint` and `ConnectionSettings` expect.
    public var host: String
    public var port: UInt16
    public var database: Int
    /// Query parameter names, in order and without duplicates. v1 applies none of them; the sheet lists them as ignored.
    public var ignoredQueryParameters: [String]

    public static let defaultPort: UInt16 = 6379
    /// Bounds what a paste can make the parser walk.
    static let lengthLimit = 4096

    public init(tls: Bool = false, username: String? = nil, password: Data? = nil, host: String, port: UInt16 = defaultPort, database: Int = 0, ignoredQueryParameters: [String] = []) {
        self.tls = tls; self.username = username; self.password = password; self.host = host; self.port = port; self.database = database
        self.ignoredQueryParameters = ignoredQueryParameters
    }

    /// True when pasted text looks like a connection URL, so ⌘V anywhere on the sheet tries to parse it.
    public static func isCandidate(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("redis://") || lowered.hasPrefix("rediss://")
    }

    public init(parsing text: String) throws(RedisURLError) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Raw spaces and control characters never belong in a URL; refusing them also keeps them out of every field.
        guard !text.isEmpty, text.utf8.count <= Self.lengthLimit, !ConnectionSettings.hasControl(text), !text.contains(" ") else { throw .notAURL }
        guard let schemeEnd = text.range(of: "://") else { throw .notAURL }
        switch text[..<schemeEnd.lowerBound].lowercased() {
        case "redis": tls = false
        case "rediss": tls = true
        default: throw .unsupportedScheme
        }
        var rest = text[schemeEnd.upperBound...]
        // A fragment has no meaning for a connection; refusing it beats silently dropping part of the paste.
        guard !rest.contains("#") else { throw .notAURL }
        var query: Substring?
        if let mark = rest.firstIndex(of: "?") { query = rest[rest.index(after: mark)...]; rest = rest[..<mark] }
        var path: Substring = ""
        if let slash = rest.firstIndex(of: "/") { path = rest[rest.index(after: slash)...]; rest = rest[..<slash] }

        // The last "@" splits userinfo from host, so an unencoded "@" in a password still parses as most clients do.
        var hostPort = rest
        username = nil; password = nil
        if let at = rest.lastIndex(of: "@") {
            let userinfo = rest[..<at]; hostPort = rest[rest.index(after: at)...]
            let colon = userinfo.firstIndex(of: ":")
            let user = try Self.decode(colon.map { userinfo[..<$0] } ?? userinfo)
            // Empty parts ("redis://:@h", "redis://app:@h") mean absent, so they never clear or set an empty value.
            if !user.isEmpty {
                // ConnectionSettings stores the ACL user as text; the same rules as the editor apply.
                guard let name = String(data: user, encoding: .utf8), name.utf8.count <= 256, !ConnectionSettings.hasControl(name), !name.contains(" ") else {
                    throw .invalidUserinfo
                }
                username = name
            }
            if let colon {
                let secret = try Self.decode(userinfo[userinfo.index(after: colon)...])
                password = secret.isEmpty ? nil : secret
            }
        }
        (host, port) = try Self.hostAndPort(hostPort)

        // "/" alone or no path selects database 0.
        if path.isEmpty {
            database = 0
        } else {
            guard let index = Self.decimal(path), ConnectionSettings.databaseRange.contains(index) else { throw .invalidDatabase }
            database = index
        }

        var names: [String] = []
        for pair in (query ?? "").split(separator: "&") {
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
            // "+" is a space in form-encoded queries; the name is only displayed.
            let decoded = try Self.decode(Substring(rawName.replacingOccurrences(of: "+", with: " ")))
            guard let name = String(data: decoded, encoding: .utf8) else { throw .invalidEncoding }
            if !name.isEmpty, !ConnectionSettings.hasControl(name), !names.contains(name) { names.append(name) }
        }
        ignoredQueryParameters = names
    }

    private static func hostAndPort(_ text: Substring) throws(RedisURLError) -> (String, UInt16) {
        let host: String
        var portText: Substring?
        if text.hasPrefix("[") {
            // IPv6 literal; a zone ID is written "%25<zone>" (RFC 6874).
            guard let close = text.firstIndex(of: "]") else { throw .invalidHost }
            let literal = text[text.index(after: text.startIndex)..<close]
            let after = text[text.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { throw .invalidHost }
                portText = after.dropFirst()
            }
            guard let decoded = String(data: try decode(literal), encoding: .utf8) else { throw .invalidHost }
            let parts = decoded.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            // A real IPv6 address (inet_pton), and a zone that is an interface name or number: never empty or stray brackets.
            var address = in6_addr()
            guard parts[0].contains(":"), inet_pton(AF_INET6, String(parts[0]), &address) == 1 else { throw .invalidHost }
            if parts.count == 2 { guard !parts[1].isEmpty, parts[1].unicodeScalars.allSatisfy(zoneAllowed.contains) else { throw .invalidHost } }
            host = decoded
        } else {
            // An unbracketed host has at most one ":", the port separator; a bare IPv6 address is ambiguous.
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw .invalidHost }
            if parts.count == 2 { portText = parts[1] }
            // Brackets and "%" only belong to a bracketed IPv6 literal; "%5B..%5D" must not smuggle one in.
            guard let decoded = String(data: try decode(parts[0]), encoding: .utf8), !decoded.contains(where: { ":[]%".contains($0) }) else { throw .invalidHost }
            host = decoded
        }
        guard ConnectionSettings.isHost(host) else { throw .invalidHost }
        guard let portText else { return (host, defaultPort) }
        guard let value = decimal(portText), let port = UInt16(exactly: value), port > 0 else { throw .invalidPort }
        return (host, port)
    }

    private static let zoneAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Up to five ASCII digits. `Int` alone would accept a sign, and `isNumber` alone non-ASCII digits such as "٦".
    private static func decimal(_ text: Substring) -> Int? {
        guard text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// Percent-decodes to bytes: a password may hold any byte, including ones that are not UTF-8.
    private static func decode(_ text: Substring) throws(RedisURLError) -> Data {
        var bytes: [UInt8] = []
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else { bytes.append(byte); continue }
            guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else { throw .invalidEncoding }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension RedisURL {
    /// The URL a profile is copied as (INT-04): never the password, which stays in the Keychain.
    public init(settings: ConnectionSettings) {
        self.init(tls: settings.tls != nil, username: settings.username, host: settings.host, port: settings.port, database: settings.database)
    }

    /// `redis://user@host:port/db`. The password is never written, even when `password` is set; query parameters too.
    public var string: String {
        let user = username.map { Self.encode($0, allowed: Self.userAllowed) + "@" } ?? ""
        // The editor accepts a bracketed IPv6 host; strip the brackets so they are not doubled.
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let hostPart = bareHost.contains(":") ? "[" + Self.encode(bareHost, allowed: Self.ipv6Allowed) + "]" : bareHost
        return "\(tls ? "rediss" : "redis")://\(user)\(hostPart):\(port)/\(database)"
    }

    /// RFC 3986 unreserved characters plus sub-delims; ":" and "@" are encoded so the userinfo parses back unchanged.
    private static let userAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=")
    /// Only the zone separator "%" needs encoding inside brackets.
    private static let ipv6Allowed = userAllowed.union(CharacterSet(charactersIn: ":"))

    private static func encode(_ text: String, allowed: CharacterSet) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }

    /// Fills the editor's connection fields from the URL; every other setting (name, label, tunnel, timeouts, TLS
    /// server name and CA) is kept. A blank name takes the host, so a pasted URL is ready to save.
    public func applied(to settings: ConnectionSettings) -> ConnectionSettings {
        var result = settings
        result.host = host; result.port = port; result.username = username; result.database = database
        result.tls = tls ? (settings.tls ?? TLSSettings()) : nil
        if result.name.trimmingCharacters(in: .whitespaces).isEmpty { result.name = String(host.prefix(ConnectionSettings.nameLimit)) }
        return result
    }
}

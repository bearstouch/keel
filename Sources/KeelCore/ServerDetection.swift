import Foundation
import KeelRESP

/// The server families Keel recognises (INT-01). Anything else that speaks RESP is `.unrecognized` and still works.
public enum ServerKind: String, Sendable, Codable, CaseIterable {
    case redis, valkey, dragonfly, unrecognized

    public var displayName: String {
        switch self {
        case .redis: return "Redis"
        case .valkey: return "Valkey"
        case .dragonfly: return "Dragonfly"
        case .unrecognized: return "Redis-compatible (unrecognized)"
        }
    }
}

/// A dotted server version. `text` is the field as reported; `components` are its leading numbers, so `df-v1.21.2`
/// is 1.21.2 and `7.2.4-rc1` is 7.2.4. Compares numerically with missing components as 0 (6.0 == 6.0.0).
public struct ServerVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var text: String
    public var components: [Int]

    /// Nil when the text holds no number at all.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Skip a vendor prefix (`df-v`, `v`) up to the first digit, then read `N(.N)*`.
        guard let start = trimmed.firstIndex(where: \.isASCIIDigit) else { return nil }
        var components: [Int] = []
        for part in trimmed[start...].split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix(while: \.isASCIIDigit)
            // An empty or overflowing part ends the version; so does a suffix (`4-rc1` keeps 4, then stops).
            guard !digits.isEmpty, let value = Int(digits) else { break }
            components.append(value)
            if digits.count != part.count { break }
        }
        guard !components.isEmpty else { return nil }
        self.text = trimmed; self.components = components
    }

    public var major: Int { components[0] }
    public var minor: Int { component(1) }
    public var description: String { text }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool { compare(lhs, rhs) == 0 }
    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool { compare(lhs, rhs) < 0 }

    /// Missing trailing components read as 0, so 6.0 and 6.0.0 compare equal.
    private func component(_ index: Int) -> Int { index < components.count ? components[index] : 0 }

    private static func compare(_ lhs: ServerVersion, _ rhs: ServerVersion) -> Int {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = lhs.component(index), b = rhs.component(index)
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

/// How the node runs (FR-CN11): `redis_mode` from `INFO server`, then `role` from `INFO replication`.
public enum ServerMode: String, Sendable, Codable {
    case standalone, replica, cluster, sentinel
}

/// What Keel detected about one server: family, version, mode and the cluster banner flag (FR-CN11, INT-02).
public struct ServerIdentity: Sendable, Equatable {
    public var kind: ServerKind
    /// Nil for an unrecognized server that reports no usable version field.
    public var version: ServerVersion?
    /// `redis_version` as reported, which Valkey and Dragonfly also send; it selects the bundled command catalog
    /// when `COMMAND` is unavailable (INT-02).
    public var redisCompatibleVersion: ServerVersion?
    public var mode: ServerMode
    /// `role` from `INFO replication` (`master`, `slave`, `replica`); nil when that section wasn't sent.
    public var role: String?

    public init(kind: ServerKind, version: ServerVersion?, redisCompatibleVersion: ServerVersion?, mode: ServerMode, role: String?) {
        self.kind = kind; self.version = version; self.redisCompatibleVersion = redisCompatibleVersion; self.mode = mode; self.role = role
    }

    /// "Valkey 8.1.1", or the bare family name when no version is known.
    public var displayName: String { version.map { "\(kind.displayName) \($0)" } ?? kind.displayName }

    /// A cluster node browses only its own slots in v1 (cluster browsing is P2), so the tab says so.
    public var showsClusterBanner: Bool { mode == .cluster }
    public static let clusterBannerText = "Cluster mode: browsing this node only"
}

/// `INFO` text as fields: `key:value` lines, `#` section headers and blank lines skipped. Later sections may repeat a
/// key; the first one wins, so `INFO server` text placed before `INFO replication` keeps its values.
public enum InfoFields {
    public static func parse(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil else { continue }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// The text of an `INFO` reply: a bulk string (RESP2) or a verbatim string (RESP3). Nil for anything else.
    public static func text(of reply: RESPValue) -> String? {
        switch reply {
        case .bulkString(let bytes), .simpleString(let bytes), .verbatim(_, let bytes): return String(decoding: bytes, as: UTF8.self)
        case .attribute(_, let inner): return text(of: inner)
        default: return nil
        }
    }
}

/// The data-driven detection rules of `Resources/ServerDetection.json` (INT-02): tried in order, first match wins.
public struct ServerDetectionRules: Sendable, Equatable, Decodable {
    public struct Condition: Sendable, Equatable, Decodable {
        public var field: String
        /// Case-insensitive value to match; nil means the field only has to be present.
        public var equals: String?
    }

    public struct Rule: Sendable, Equatable, Decodable {
        public var server: ServerKind
        /// The rule matches when any condition holds.
        public var anyOf: [Condition]
        /// Fields tried in order for the version (Valkey 7.2 builds without `valkey_version` fall back to `redis_version`).
        public var versionFields: [String]
        /// Older servers of this family are refused with `UNSUPPORTED_SERVER`.
        public var minimumVersion: String?
    }

    public var version: Int
    public var rules: [Rule]

    /// The rules bundled with Keel. A missing or broken resource is a build defect, caught by `ServerDetectionTests`.
    public static let bundled: ServerDetectionRules = {
        guard let url = Bundle.keelCore.url(forResource: "ServerDetection", withExtension: "json"), let data = try? Data(contentsOf: url),
            let rules = try? JSONDecoder().decode(ServerDetectionRules.self, from: data)
        else { preconditionFailure("Resources/ServerDetection.json is missing or invalid") }
        return rules
    }()
}

/// Identifies a server from its `INFO server` (+ `INFO replication`) text (FR-CN11, INT-02).
public struct ServerDetector: Sendable {
    public var rules: ServerDetectionRules

    public init(rules: ServerDetectionRules = .bundled) { self.rules = rules }

    /// Throws `UNSUPPORTED_SERVER` for a family below its minimum version (Redis < 6.0), so no tab opens.
    public func detect(info: String) throws(ConnectionFailure) -> ServerIdentity {
        try detect(fields: InfoFields.parse(info))
    }

    public func detect(fields: [String: String]) throws(ConnectionFailure) -> ServerIdentity {
        let redisVersion = fields["redis_version"].flatMap(ServerVersion.init)
        let role = fields["role"].map { $0.lowercased() }
        let mode: ServerMode
        switch fields["redis_mode"]?.lowercased() {
        case "cluster": mode = .cluster
        case "sentinel": mode = .sentinel
        default: mode = role == "slave" || role == "replica" ? .replica : .standalone
        }
        // No rule matched: still a RESP server, so it connects as unrecognized with no minimum to enforce.
        guard let rule = rules.rules.first(where: { $0.matches(fields) }) else {
            return ServerIdentity(kind: .unrecognized, version: nil, redisCompatibleVersion: redisVersion, mode: mode, role: role)
        }
        let version = rule.versionFields.lazy.compactMap { fields[$0].flatMap(ServerVersion.init) }.first
        if let minimum = rule.minimumVersion.flatMap(ServerVersion.init) {
            // A matched family with no parseable version can't prove it is new enough: refuse rather than guess.
            guard let version, version >= minimum else { throw ConnectionFailure(unsupported: rule.server, version: version, minimum: minimum) }
        }
        return ServerIdentity(kind: rule.server, version: version, redisCompatibleVersion: redisVersion, mode: mode, role: role)
    }
}

extension ServerDetectionRules.Rule {
    fileprivate func matches(_ fields: [String: String]) -> Bool {
        anyOf.contains { condition in
            guard let value = fields[condition.field] else { return false }
            return condition.equals.map { value.caseInsensitiveCompare($0) == .orderedSame } ?? true
        }
    }
}

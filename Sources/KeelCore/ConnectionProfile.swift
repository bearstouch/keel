import Foundation
import KeelSSH

/// The eight label colors of FR-CN02. Each has an editable name in `ConnectionsDocument.labels`.
public enum LabelColor: String, Codable, CaseIterable, Sendable {
    case none, red, orange, yellow, green, blue, purple, gray
}

/// A color label's user-facing settings. The red label is the built-in **Production** label (FR-SF02): it is always
/// treated as production; any other label can opt in.
public struct ProfileLabel: Codable, Equatable, Sendable {
    public var color: LabelColor
    public var name: String
    public var treatAsProduction: Bool

    public init(color: LabelColor, name: String, treatAsProduction: Bool = false) {
        self.color = color; self.name = name; self.treatAsProduction = color == .production || treatAsProduction
    }

    public static let nameLimit = 40

    /// The labels a new install starts with, in display order.
    public static let defaults: [ProfileLabel] = LabelColor.allCases.map { color in
        switch color {
        case .red: ProfileLabel(color: .red, name: "Production", treatAsProduction: true)
        default: ProfileLabel(color: color, name: color.rawValue.capitalized)
        }
    }
}

extension LabelColor {
    /// The color of the built-in Production label.
    public static let production = LabelColor.red
}

public struct TLSSettings: Codable, Equatable, Sendable {
    /// SNI and certificate-name override; nil uses the host.
    public var serverName: String?
    /// A PEM CA bundle the user picked; its fingerprint lives in `known-ca.json` (FR-CN04).
    public var caFile: String?
    public var skipVerification: Bool

    public init(serverName: String? = nil, caFile: String? = nil, skipVerification: Bool = false) {
        self.serverName = serverName; self.caFile = caFile; self.skipVerification = skipVerification
    }
}

/// An SSH tunnel through a saved SSH host or an inline destination (FR-CN05). The Redis host and port are resolved
/// from the SSH server's side.
public enum TunnelSettings: Codable, Hashable, Sendable {
    case savedHost(id: UUID)
    case inline(destination: String, user: String?, port: Int?, identityFile: String?)
}

/// Everything the profile editor edits (FR-CN01). Optional fields fall back to the app's settings (FR-AP09).
public struct ConnectionSettings: Codable, Equatable, Sendable {
    public var name: String
    public var label: LabelColor
    public var host: String
    public var port: UInt16
    /// ACL user; nil authenticates with `requirepass` only.
    public var username: String?
    public var database: Int
    /// nil connects without TLS.
    public var tls: TLSSettings?
    public var tunnel: TunnelSettings?
    public var readOnly: Bool
    public var connectTimeoutMilliseconds: Int?
    public var commandTimeoutMilliseconds: Int?
    /// Namespace separator for the key tree (FR-KB03); nil uses the browser default.
    public var separator: String?
    /// `CLIENT SETNAME` value; nil uses the Advanced default.
    public var clientName: String?
    /// FR-CN15: off by default.
    public var reconnectOnLaunch: Bool

    public init(
        name: String, label: LabelColor = .none, host: String = "127.0.0.1", port: UInt16 = 6379, username: String? = nil, database: Int = 0, tls: TLSSettings? = nil,
        tunnel: TunnelSettings? = nil, readOnly: Bool = false, connectTimeoutMilliseconds: Int? = nil, commandTimeoutMilliseconds: Int? = nil, separator: String? = nil,
        clientName: String? = nil, reconnectOnLaunch: Bool = false
    ) {
        self.name = name; self.label = label; self.host = host; self.port = port; self.username = username; self.database = database; self.tls = tls
        self.tunnel = tunnel; self.readOnly = readOnly; self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
        self.commandTimeoutMilliseconds = commandTimeoutMilliseconds; self.separator = separator; self.clientName = clientName
        self.reconnectOnLaunch = reconnectOnLaunch
    }

    /// The fields a saved password and agent approvals are bound to (02 Architecture → Keychain items, 05 API).
    /// Changing any of them reaches a different server, so the password is never offered to it.
    public struct ConnectionKey: Hashable, Sendable {
        public var host: String
        public var port: UInt16
        public var username: String?
        public var serverName: String?
        public var tunnel: TunnelSettings?
    }

    public var connectionKey: ConnectionKey { ConnectionKey(host: host, port: port, username: username, serverName: tls?.serverName, tunnel: tunnel) }
}

public enum ProfileField: String, Sendable, CaseIterable {
    case name, host, port, username, password, database, serverName, caFile, tunnel, connectTimeout, commandTimeout, separator, clientName, folder, label
}

extension ConnectionSettings {
    public static let nameLimit = 128
    public static let databaseRange = 0...65_535
    public static let timeoutRange = 100...600_000

    /// Rejects what the editor must never save and what a hand-edited `connections.json` must never smuggle into a
    /// connect: control characters, option-like tunnel values, out-of-range numbers. The first bad field is reported.
    public func validated() throws(ProfileStoreError) -> ConnectionSettings {
        guard Self.isName(name, limit: Self.nameLimit) else { throw .invalid(.name) }
        guard Self.isHost(host) else { throw .invalid(.host) }
        guard port > 0 else { throw .invalid(.port) }
        if let username { guard !username.isEmpty, username.utf8.count <= 256, !Self.hasControl(username), !username.contains(" ") else { throw .invalid(.username) } }
        guard Self.databaseRange.contains(database) else { throw .invalid(.database) }
        if let tls {
            if let serverName = tls.serverName { guard Self.isHost(serverName) else { throw .invalid(.serverName) } }
            if let caFile = tls.caFile { guard caFile.hasPrefix("/"), !Self.hasControl(caFile) else { throw .invalid(.caFile) } }
        }
        if let tunnel { try Self.validate(tunnel, redisHost: host, redisPort: port) }
        for (value, field) in [(connectTimeoutMilliseconds, ProfileField.connectTimeout), (commandTimeoutMilliseconds, .commandTimeout)] {
            if let value { guard Self.timeoutRange.contains(value) else { throw .invalid(field) } }
        }
        // FR-KB03: any 1–4 byte separator.
        if let separator { guard (1...4).contains(separator.utf8.count), !Self.hasControl(separator) else { throw .invalid(.separator) } }
        // CLIENT SETNAME refuses spaces; newlines would break the console echo.
        if let clientName { guard !clientName.isEmpty, clientName.utf8.count <= 128, !Self.hasControl(clientName), !clientName.contains(" ") else { throw .invalid(.clientName) } }
        return self
    }

    /// The tunnel must produce a valid ssh argument array; the saved-host case checks only the forward.
    private static func validate(_ tunnel: TunnelSettings, redisHost: String, redisPort: UInt16) throws(ProfileStoreError) {
        let configuration: SSHTunnelConfiguration
        switch tunnel {
        case .savedHost: configuration = SSHTunnelConfiguration(destination: "saved-host", redisHost: redisHost, redisPort: redisPort)
        case .inline(let destination, let user, let port, let identityFile):
            configuration = SSHTunnelConfiguration(destination: destination, user: user, port: port, identityFile: identityFile, redisHost: redisHost, redisPort: redisPort)
        }
        do { _ = try SSHTunnelArguments.arguments(for: configuration, socketPath: "/validation.sock") } catch { throw .invalid(error == .invalidRedisHost ? .host : .tunnel) }
    }

    /// A hostname, an IPv4 address or an IPv6 literal (bare or in brackets); never an option-like or spaced value.
    static func isHost(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%")
        return !host.isEmpty && host.utf8.count <= 253 && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// A display name: not blank, at most `limit` characters, no control characters.
    static func isName(_ name: String, limit: Int) -> Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= limit && !hasControl(name) }

    static func hasControl(_ text: String) -> Bool { text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x7F } }
}

/// A saved profile: the editor's settings plus store-owned metadata. Secrets are never here; `hasPassword` only
/// records that `Keel Connection` / `<id>` holds one, and `hasTLSSecret` the same for `Keel TLS` / `<id>`.
public struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var settings: ConnectionSettings
    /// nil: top level of the sidebar. Folders nest one level only (FR-CN13).
    public var folderID: UUID?
    /// Stamped from the store's counter on every change; stale editors get `CONFLICT`.
    public var revision: UInt64
    /// Advances only when `settings.connectionKey` changes; the saved password and agent approvals bind to it.
    public var connectionRevision: UInt64
    public var hasPassword: Bool
    public var hasTLSSecret: Bool

    public init(id: UUID, settings: ConnectionSettings, folderID: UUID? = nil, revision: UInt64, connectionRevision: UInt64? = nil, hasPassword: Bool = false, hasTLSSecret: Bool = false) {
        self.id = id; self.settings = settings; self.folderID = folderID; self.revision = revision
        self.connectionRevision = connectionRevision ?? revision; self.hasPassword = hasPassword; self.hasTLSSecret = hasTLSSecret
    }
}

public struct ProfileFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var collapsed: Bool
    public var revision: UInt64

    public init(id: UUID, name: String, collapsed: Bool = false, revision: UInt64) { self.id = id; self.name = name; self.collapsed = collapsed; self.revision = revision }
}

/// `connections.json` (02 Architecture → Persistence). Array order is display order: folders among themselves, and
/// profiles within their folder (or the top level).
public struct ConnectionsDocument: PersistedDocument, Equatable {
    public static let file = PersistedFile.connections
    public static let currentVersion = 1

    public var revision: UInt64
    public var folders: [ProfileFolder]
    public var profiles: [ConnectionProfile]
    /// One entry per `LabelColor`, in `LabelColor.allCases` order.
    public var labels: [ProfileLabel]

    public init(revision: UInt64 = 0, folders: [ProfileFolder] = [], profiles: [ConnectionProfile] = [], labels: [ProfileLabel] = ProfileLabel.defaults) {
        self.revision = revision; self.folders = folders; self.profiles = profiles; self.labels = labels
    }

    private enum CodingKeys: String, CodingKey { case revision, folders, profiles, labels }

    /// Re-validates every record, since anyone with access to the state folder could have edited the file. A file
    /// that fails is reported corrupt, so it goes through recovery instead of being used or overwritten.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(UInt64.self, forKey: .revision)
        folders = try values.decode([ProfileFolder].self, forKey: .folders)
        profiles = try values.decode([ConnectionProfile].self, forKey: .profiles)
        let stored = try values.decodeIfPresent([ProfileLabel].self, forKey: .labels) ?? []
        // Missing colors get their default; the Production label stays production (its initializer enforces it).
        labels = ProfileLabel.defaults.map { fallback in
            stored.last { $0.color == fallback.color }.map { ProfileLabel(color: $0.color, name: $0.name, treatAsProduction: $0.treatAsProduction) } ?? fallback
        }
        let folderIDs = Set(folders.map(\.id))
        guard
            // Bounded so `revision + 1` can never overflow on a hand-edited file.
            revision <= UInt64(Int64.max), folderIDs.count == folders.count, Set(profiles.map(\.id)).count == profiles.count,
            // A higher record revision would let a later edit reuse it and defeat stale-editor checks.
            folders.allSatisfy({ $0.revision <= revision && Self.isFolderName($0.name) }),
            profiles.allSatisfy({ $0.revision <= revision && $0.connectionRevision <= $0.revision && ($0.folderID.map(folderIDs.contains) ?? true) }),
            profiles.allSatisfy({ (try? $0.settings.validated()) != nil }),
            labels.allSatisfy({ Self.isLabelName($0.name) })
        else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid connections document")) }
    }

    public func label(_ color: LabelColor) -> ProfileLabel { labels.first { $0.color == color } ?? ProfileLabel(color: color, name: color.rawValue.capitalized) }

    static func isFolderName(_ name: String) -> Bool { ConnectionSettings.isName(name, limit: ConnectionSettings.nameLimit) }
    static func isLabelName(_ name: String) -> Bool { ConnectionSettings.isName(name, limit: ProfileLabel.nameLimit) }
}

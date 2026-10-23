import Foundation
import KeelCore

/// What one key-list row shows and VoiceOver reads (FR-KB03, FR-KB06, 08 Design → Key list). Built for visible rows
/// only, from a `NamespaceEntry`; the name is display text and never goes back into a command.
public struct KeyListRow: Equatable, Sendable {
    public var child: NamespaceChild
    /// The leaf segment (tree) or the full key name (flat), escaped by `KeyDisplay`.
    public var name: String
    /// Loaded keys at or below a folder; 1 for a key.
    public var keyCount: Int
    public var type: KeyType
    /// Short TTL ("3d", "12m") for an expiring key, nil otherwise; KEEL-024 fills it.
    public var ttl: String?

    public init(child: NamespaceChild, name: String, keyCount: Int, type: KeyType = .unknown, ttl: String? = nil) {
        self.child = child; self.name = name; self.keyCount = keyCount; self.type = type; self.ttl = ttl
    }

    public init(_ entry: NamespaceEntry, ttl: String? = nil) {
        self.init(child: entry.child, name: KeyDisplay.name(entry.name), keyCount: entry.keyCount, type: entry.metadata.type, ttl: ttl)
    }

    public var isFolder: Bool { if case .folder = child { true } else { false } }

    /// Muted text beside the name: a folder's key count, or a key's TTL only when it expires (rows stay quiet).
    public var meta: String? { isFolder ? KeyIndexFooter.grouped(keyCount) : ttl }

    /// The badge's text (DS-04: never color only); nil for folders and keys whose type isn't loaded yet.
    public var badge: String? { isFolder ? nil : Self.badge(type) }

    /// "user, 48,210 keys" for a folder; "user:1042, hash, expires in 3d" for a key. The outline adds the
    /// expanded state and selection itself.
    public var accessibilityLabel: String {
        if isFolder { return "\(name), \(KeyIndexFooter.grouped(keyCount)) \(keyCount == 1 ? "key" : "keys")" }
        return ([name, Self.spoken(type), ttl.map { "expires in \($0)" }] as [String?]).compactMap { $0 }.joined(separator: ", ")
    }

    static func badge(_ type: KeyType) -> String? {
        switch type {
        case .unknown: nil
        case .string: "STR"
        case .hash: "HASH"
        case .list: "LIST"
        case .set: "SET"
        case .zset: "ZSET"
        case .stream: "STREAM"
        case .other: "OTHER"
        }
    }

    /// Words for VoiceOver: "ZSET" read letter by letter helps no one.
    static func spoken(_ type: KeyType) -> String? {
        switch type {
        case .unknown: nil
        case .string: "string"
        case .hash: "hash"
        case .list: "list"
        case .set: "set"
        case .zset: "sorted set"
        case .stream: "stream"
        case .other: "other type"
        }
    }
}

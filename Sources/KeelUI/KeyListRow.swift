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
    /// Short TTL ("3d", "1m 30s") for an expiring key, "expired" for one that is gone, nil otherwise (FR-KB06).
    public var ttl: String?
    /// The TTL in full for VoiceOver ("1 minute 30 seconds"); the row has room only for the short form.
    public var spokenTTL: String?
    /// The memory size ("4.1 KB"), only while Show sizes is on and once measured (FR-KB07).
    public var size: String?
    /// The facts `ttl` and `size` are derived from; `presented(at:showsSizes:)` re-derives them as time passes or
    /// sizes are toggled, without asking the server (NFR-PF07).
    public var expiry: RowExpiry
    public var memory: KeySize

    public init(child: NamespaceChild, name: String, keyCount: Int, type: KeyType = .unknown, ttl: String? = nil, size: String? = nil) {
        self.child = child; self.name = name; self.keyCount = keyCount; self.type = type; self.ttl = ttl; self.spokenTTL = ttl; self.size = size
        expiry = .unknown; memory = .unknown
    }

    /// A row from the index; call `presented(at:showsSizes:)` before showing it.
    public init(_ entry: NamespaceEntry) {
        self.init(child: entry.child, name: KeyDisplay.name(entry.name), keyCount: entry.keyCount, type: entry.metadata.type)
        expiry = entry.metadata.expiry; memory = entry.metadata.size
    }

    /// The row as shown at `now` (milliseconds on the `RowMetadataLoader` clock): the TTL counts down locally and the
    /// size shows only while `showsSizes` is on.
    public func presented(at now: Int64, showsSizes: Bool) -> KeyListRow {
        var row = self
        switch expiry {
        case .unknown, .persistent: break
        case .gone: row.ttl = "expired"; row.spokenTTL = "expired"
        case .expires(let deadline):
            row.ttl = TTLFormatter.short(milliseconds: deadline - now); row.spokenTTL = TTLFormatter.spoken(milliseconds: deadline - now)
        }
        if case .bytes(let bytes) = memory { row.size = showsSizes ? KeySizeFormatter.short(bytes: bytes) : nil }
        return row
    }

    /// Takes type, expiry and size from a fresher row of the same key, keeping this row's name (a tree leaf or a full name).
    mutating func adopt(metadataOf fresh: KeyListRow) { type = fresh.type; expiry = fresh.expiry; memory = fresh.memory }

    /// A key row whose type or expiry — or, with sizes shown, size — isn't known yet; a gone key needs nothing more.
    func needsMetadata(showsSizes: Bool) -> Bool {
        guard !isFolder, expiry != .gone else { return false }
        return type == .unknown || expiry == .unknown || (showsSizes && memory == .unknown)
    }

    public var isFolder: Bool { if case .folder = child { true } else { false } }

    /// Muted text beside the name: a folder's key count, or a key's TTL only when it expires (rows stay quiet) and its
    /// size when asked for.
    public var meta: String? {
        if isFolder { return KeyIndexFooter.grouped(keyCount) }
        let parts = [ttl, size].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The badge's text (DS-04: never color only); nil for folders and keys whose type isn't loaded yet.
    public var badge: String? { isFolder ? nil : Self.badge(type) }

    /// "user, 48,210 keys" for a folder; "user:1042, hash, expires in 3 days, 4.1 KB" for a key. The outline adds the
    /// expanded state and selection itself.
    public var accessibilityLabel: String {
        if isFolder { return "\(name), \(KeyIndexFooter.grouped(keyCount)) \(keyCount == 1 ? "key" : "keys")" }
        let expires = spokenTTL.map { $0 == "expired" ? $0 : "expires in \($0)" }
        return ([name, Self.spoken(type), expires, size] as [String?]).compactMap { $0 }.joined(separator: ", ")
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

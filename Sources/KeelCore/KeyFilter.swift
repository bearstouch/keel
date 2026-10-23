import Foundation

/// The type filter's choices (FR-KB05). The six core types go to the server as `SCAN … TYPE`; `other` (module types
/// such as `ReJSON-RL`, Redis 8 vector sets, anything new) has no single SCAN name, so it is applied on this Mac.
public enum KeyTypeFilter: String, Sendable, Equatable, CaseIterable {
    case string, hash, list, set, zset, stream, other

    /// The type the matching keys have, so filtered pages can fill the badge without a `TYPE` round trip.
    public var keyType: KeyType {
        switch self {
        case .string: .string
        case .hash: .hash
        case .list: .list
        case .set: .set
        case .zset: .zset
        case .stream: .stream
        case .other: .other
        }
    }

    /// The menu title: SCAN's own names for the core types.
    public var title: String { self == .other ? "Other (module types)" : rawValue }
}

extension KeyType {
    /// `TYPE`'s reply as a key type; nil for `none` (the key is gone). Unrecognized names are module or newer types.
    public init?(typeName: Data) {
        switch String(decoding: typeName, as: UTF8.self).lowercased() {
        case "none": return nil
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .zset
        case "stream": self = .stream
        default: self = .other
        }
    }
}

/// The browser's server-side filters (FR-KB05): a glob pattern sent as `SCAN … MATCH` and a type sent as
/// `SCAN … TYPE`, except `other`, which `KeyIndex` checks per key with `TYPE` after each page. Changing either
/// restarts the scan (`KeyIndex.restart(filter:)`).
public struct KeyFilter: Sendable, Equatable {
    /// The glob's bytes; nil lists every key (an empty field or `*` both mean "no pattern").
    public var pattern: Data?
    public var type: KeyTypeFilter?

    public init(pattern: Data? = nil, type: KeyTypeFilter? = nil) {
        self.pattern = pattern.flatMap { $0.isEmpty || $0 == Data("*".utf8) ? nil : $0 }
        self.type = type
    }

    /// The pattern field's text as typed; glob syntax passes through unchanged.
    public init(pattern: String, type: KeyTypeFilter? = nil) { self.init(pattern: Data(pattern.utf8), type: type) }

    public var isActive: Bool { pattern != nil || type != nil }

    /// `MATCH`'s argument.
    public var scanMatch: Data? { pattern }

    /// `TYPE`'s argument; nil for `other`, which SCAN can't express.
    public var scanType: Data? { type.flatMap { $0 == .other ? nil : Data($0.rawValue.utf8) } }

    /// The type a key must have to be kept after the page arrives; nil when the server already filtered (or nothing).
    public var clientSideType: KeyTypeFilter? { type == .other ? .other : nil }

    /// What the filter bar says while the type is checked here rather than by the server (AC4).
    public var clientSideNotice: String? {
        clientSideType == nil ? nil : "Type filtered on this Mac: SCAN can't select module types, so each page's keys are checked with TYPE."
    }

    /// The SCAN for one page under this filter.
    public func scan(cursor: Data, count: Int) -> DataOperation { .scan(cursor: cursor, match: scanMatch, count: count, type: scanType) }

    /// Shown in the glob help popover: Redis's `stringmatchlen` syntax, which `MATCH` uses.
    public static let globHelp: [(syntax: String, meaning: String)] = [
        ("*", "any run of characters, including none"),
        ("?", "exactly one character"),
        ("[abc]", "one of a, b or c"),
        ("[^a] or [!a]", "any one character except a"),
        ("[a-z]", "one character in the range"),
        ("\\*", "a literal *, ? or [ (escape with a backslash)")
    ]
}

/// A substring filter over the keys already loaded (FR-KB05 "quick local filter"). It never talks to the server.
/// The query is matched against the key's bytes, ignoring ASCII case, so `User` finds `user:1`.
public struct LocalKeyQuery: Sendable, Equatable {
    /// Lowercased query bytes; empty matches every key.
    public let needle: [UInt8]

    public init(_ text: String) { needle = Array(text.utf8).map(Self.fold) }

    public var isEmpty: Bool { needle.isEmpty }

    /// Lowercases A–Z only: the wrapping subtraction sends every byte below `A` past 26.
    @inline(__always) static func fold(_ byte: UInt8) -> UInt8 { byte &- 0x41 < 26 ? byte | 0x20 : byte }

    /// Whether `haystack` contains the needle, ASCII case ignored.
    func matches(_ haystack: UnsafeRawBufferPointer) -> Bool {
        let count = needle.count
        guard count > 0 else { return true }
        guard haystack.count >= count else { return false }
        return needle.withUnsafeBufferPointer { needle in
            let first = needle[0]
            var start = 0
            let last = haystack.count - count
            while start <= last {
                if Self.fold(haystack[start]) == first {
                    var offset = 1
                    while offset < count, Self.fold(haystack[start + offset]) == needle[offset] { offset += 1 }
                    if offset == count { return true }
                }
                start += 1
            }
            return false
        }
    }
}

/// One chunk of a local search: the matching keys (index order) and where the next chunk starts.
public struct LocalKeyMatches: Sendable, Equatable {
    public var indices: [Int]
    /// Keys `0..<searchedThrough` have been searched; equal to the loaded count when the search caught up.
    public var searchedThrough: Int

    public init(indices: [Int], searchedThrough: Int) { self.indices = indices; self.searchedThrough = searchedThrough }
}

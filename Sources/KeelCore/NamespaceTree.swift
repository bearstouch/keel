import Foundation

/// The tree view's namespace separator: any 1–4 bytes, `:` by default, chosen per profile (FR-KB03).
public struct NamespaceSeparator: Sendable, Hashable {
    public static let `default` = NamespaceSeparator(checked: Data(":".utf8))

    public let bytes: Data

    /// Nil unless `bytes` is 1–4 bytes long.
    public init?(_ bytes: Data) {
        guard (1...4).contains(bytes.count) else { return nil }
        self.bytes = bytes
    }

    /// The profile's separator; `:` when it has none (profile validation already refuses invalid ones).
    public init(profile separator: String?) { self = separator.flatMap { NamespaceSeparator(Data($0.utf8)) } ?? .default }

    private init(checked bytes: Data) { self.bytes = bytes }
}

/// A folder of the namespace tree; `root` holds every loaded key. IDs are valid until the tree is rebuilt
/// (separator change) or the index restarts; `KeyIndex` ignores older ones, even when the new tree has that many folders.
public struct NamespaceFolderID: Sendable, Hashable {
    public static let root = NamespaceFolderID(rawValue: 0, build: 0)
    public let rawValue: Int
    /// The tree build that issued the ID; the root is the same folder in every build.
    let build: Int
}

/// One row under a folder: a sub-folder, or a key by its index in `KeyIndex`. A name can be both (`a:b` beside `a:b:c`).
public enum NamespaceChild: Sendable, Hashable {
    case folder(NamespaceFolderID)
    case key(Int)
}

/// What a visible row shows. `name` is the raw last segment; show it through `KeyDisplay`, act on `KeyIndex.key(at:)`.
public struct NamespaceEntry: Sendable, Equatable {
    public var child: NamespaceChild
    public var name: Data
    /// Loaded keys at or below a folder (FR-KB03); 1 for a key.
    public var keyCount: Int

    public init(child: NamespaceChild, name: Data, keyCount: Int) { self.child = child; self.name = name; self.keyCount = keyCount }
}

/// Read-only view of `KeyIndex`'s arena: key i is `arena[ends[i - 1] ..< ends[i]]`.
struct KeyBytes {
    let arena: UnsafeRawBufferPointer
    let ends: UnsafeBufferPointer<Int>

    func start(of index: Int) -> Int { index == 0 ? 0 : ends[index - 1] }

    subscript(index: Int) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: arena[start(of: index)..<ends[index]]) }
}

/// The namespace tree over `KeyIndex`'s keys (02 Architecture → Key index). It stores no names: a folder points at
/// the first key that created it and where its path ends in that key, and its children are a linked list mixing
/// folders and keys. A table of folders keyed by their full path finds a key's folders with one hash per level, so
/// adding a key is O(depth) and counts stay current as pages load. Children are sorted only when a folder is expanded.
///
/// Folder paths are prefixes of key bytes ending right before a separator, split left to right; a folder's path
/// alone decides every split before it, so equal paths are the same folder whatever key created them.
struct NamespaceTree {
    struct Folder {
        /// The key whose bytes hold this folder's path, and where the path ends in it.
        var sourceKey: UInt32
        var pathEnd: UInt32
        var keyCount: UInt32
        /// Head of the children list and the next sibling in the parent's list; `NamespaceTree.end` ends a list.
        var firstChild: UInt32
        var nextSibling: UInt32
    }

    /// A child reference is a folder ID, or a key index with `keyFlag` set.
    static let keyFlag: UInt32 = 1 << 31
    static let end = UInt32.max

    let separator: NamespaceSeparator
    /// Stamped on the folder IDs this tree hands out, so IDs from an earlier build are told apart.
    let build: Int
    private let separatorBytes: [UInt8]
    private(set) var folders: ContiguousArray<Folder> = [Folder(sourceKey: 0, pathEnd: 0, keyCount: 0, firstChild: end, nextSibling: end)]
    /// Next-sibling link of each key, by key index.
    private var keyNext = ContiguousArray<UInt32>()
    /// Open addressing with linear probing over folder IDs; 0 is empty (the root is never stored). Power-of-two size.
    private var slots = ContiguousArray<UInt32>(repeating: 0, count: 1_024)

    init(separator: NamespaceSeparator, build: Int = 0) { self.separator = separator; self.build = build; separatorBytes = Array(separator.bytes) }

    var keyCount: Int { keyNext.count }

    var storageBytes: Int {
        folders.capacity * MemoryLayout<Folder>.stride + keyNext.capacity * MemoryLayout<UInt32>.stride + slots.capacity * MemoryLayout<UInt32>.stride
    }

    // MARK: - Building

    /// Adds keys `keyCount ..< keys.ends.count`: the keys appended to the index since the last call, in order.
    mutating func extend(with keys: KeyBytes) {
        for index in keyCount..<keys.ends.count { insert(index, keys) }
    }

    private mutating func insert(_ index: Int, _ keys: KeyBytes) {
        let key = keys[index]
        var parent = 0, start = 0
        folders[0].keyCount += 1
        // Each separator closes one folder level; what follows the last one is the key's leaf name.
        while let split = nextSplit(in: key, from: start) {
            parent = folder(path: UnsafeRawBufferPointer(rebasing: key[..<split]), parent: parent, sourceKey: index, keys)
            folders[parent].keyCount += 1
            start = split + separatorBytes.count
        }
        keyNext.append(folders[parent].firstChild)
        folders[parent].firstChild = UInt32(index) | Self.keyFlag
    }

    /// The folder with this path, created under `parent` when it doesn't exist yet.
    private mutating func folder(path: UnsafeRawBufferPointer, parent: Int, sourceKey: Int, _ keys: KeyBytes) -> Int {
        let mask = slots.count - 1
        var slot = Self.hash(path) & mask
        while slots[slot] != 0 {
            let candidate = Int(slots[slot])
            if Self.equal(self.path(of: candidate, keys), path) { return candidate }
            slot = (slot + 1) & mask
        }
        let id = folders.count
        folders.append(Folder(sourceKey: UInt32(sourceKey), pathEnd: UInt32(path.count), keyCount: 0, firstChild: Self.end, nextSibling: folders[parent].firstChild))
        folders[parent].firstChild = UInt32(id)
        slots[slot] = UInt32(id)
        // Keep the load factor under 3/4 so probes stay short.
        if (folders.count - 1) * 4 > slots.count * 3 { rehash(capacity: slots.count * 2, keys) }
        return id
    }

    private mutating func rehash(capacity: Int, _ keys: KeyBytes) {
        var table = ContiguousArray<UInt32>(repeating: 0, count: capacity)
        let mask = capacity - 1
        for id in 1..<folders.count {
            var slot = Self.hash(path(of: id, keys)) & mask
            while table[slot] != 0 { slot = (slot + 1) & mask }
            table[slot] = UInt32(id)
        }
        slots = table
    }

    // MARK: - Reading

    /// The folder's full path ("a:b"), a prefix of its source key.
    func path(of folder: Int, _ keys: KeyBytes) -> UnsafeRawBufferPointer {
        guard folder != 0 else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(rebasing: keys[Int(folders[folder].sourceKey)][..<Int(folders[folder].pathEnd)])
    }

    /// The last segment of a folder's path or of a key: everything after the last split.
    func name(of child: NamespaceChild, _ keys: KeyBytes) -> UnsafeRawBufferPointer {
        let bytes: UnsafeRawBufferPointer
        switch child {
        case .folder(let id): bytes = path(of: id.rawValue, keys)
        case .key(let index): bytes = keys[index]
        }
        var start = 0
        while let split = nextSplit(in: bytes, from: start) { start = split + separatorBytes.count }
        return UnsafeRawBufferPointer(rebasing: bytes[start...])
    }

    /// The folder's children, sub-folders first, each group in byte order of the name.
    func children(of folder: Int, _ keys: KeyBytes) -> [NamespaceChild] {
        // Every child's name starts right after the folder's path and its separator.
        let nameStart = folder == 0 ? 0 : Int(folders[folder].pathEnd) + separatorBytes.count
        var rows: [(ref: UInt32, name: UnsafeRawBufferPointer)] = []
        var ref = folders[folder].firstChild
        while ref != Self.end {
            if ref & Self.keyFlag != 0 {
                let index = Int(ref & ~Self.keyFlag)
                rows.append((ref, UnsafeRawBufferPointer(rebasing: keys[index][nameStart...])))
                ref = keyNext[index]
            } else {
                let child = folders[Int(ref)]
                rows.append((ref, UnsafeRawBufferPointer(rebasing: keys[Int(child.sourceKey)][nameStart..<Int(child.pathEnd)])))
                ref = child.nextSibling
            }
        }
        rows.sort { lhs, rhs in
            let lhsKey = lhs.ref & Self.keyFlag, rhsKey = rhs.ref & Self.keyFlag
            return lhsKey != rhsKey ? lhsKey < rhsKey : Self.compare(lhs.name, rhs.name) < 0
        }
        return rows.map { $0.ref & Self.keyFlag != 0 ? .key(Int($0.ref & ~Self.keyFlag)) : .folder(NamespaceFolderID(rawValue: Int($0.ref), build: build)) }
    }

    // MARK: - Bytes

    /// Offset of the next separator at or after `start`, found with memchr on its first byte.
    private func nextSplit(in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        let width = separatorBytes.count
        var position = start
        while position + width <= bytes.count {
            guard let hit = memchr(base + position, Int32(separatorBytes[0]), bytes.count - width + 1 - position) else { return nil }
            let offset = base.distance(to: UnsafeRawPointer(hit))
            if width == 1 || (1..<width).allSatisfy({ bytes[offset + $0] == separatorBytes[$0] }) { return offset }
            position = offset + 1
        }
        return nil
    }

    private static func hash(_ bytes: UnsafeRawBufferPointer) -> Int {
        var hasher = Hasher()
        hasher.combine(bytes: bytes)
        return hasher.finalize()
    }

    private static func equal(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
        lhs.count == rhs.count && compare(lhs, rhs) == 0
    }

    /// Byte order, shorter first on a common prefix.
    private static func compare(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Int {
        let common = min(lhs.count, rhs.count)
        if common > 0, let left = lhs.baseAddress, let right = rhs.baseAddress {
            let order = memcmp(left, right, common)
            if order != 0 { return Int(order) }
        }
        return lhs.count - rhs.count
    }
}

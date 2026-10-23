import Foundation
import KeelRESP

/// The command that counts a type's elements for the editor's metadata line (FR-ED13).
public enum LengthCommand: String, Sendable, Equatable {
    case strlen = "STRLEN", hlen = "HLEN", llen = "LLEN", scard = "SCARD", zcard = "ZCARD", xlen = "XLEN"

    /// Nil for module and unknown types: they have no common length command.
    public init?(_ type: KeyType) {
        switch type {
        case .string: self = .strlen
        case .hash: self = .hlen
        case .list: self = .llen
        case .set: self = .scard
        case .zset: self = .zcard
        case .stream: self = .xlen
        case .unknown, .other: return nil
        }
    }

    /// "6 fields", "1 member", "512 bytes".
    public func describe(_ count: Int64) -> String {
        let unit: String
        switch self {
        case .strlen: unit = "byte"
        case .hlen: unit = "field"
        case .llen: unit = "item"
        case .scard, .zcard: unit = "member"
        case .xlen: unit = "entry"
        }
        let plural = count == 1 ? unit : (unit == "entry" ? "entries" : unit + "s")
        return "\(KeyIndexFooter.grouped(Int(clamping: count))) \(plural)"
    }
}

// MARK: - Editable values

/// One row of an open value: a string is one row, a hash one per field. `id` names the row for the changed-row dot.
public struct EditorRow: Sendable, Equatable, Identifiable {
    public var id: Data
    public var value: Data

    public init(id: Data, value: Data) { self.id = id; self.value = value }
}

/// A value as an editor loaded it, with the reads a save repeats under `WATCH` to prove it unchanged.
public struct LoadedValue: Sendable, Equatable {
    public var rows: [EditorRow]
    public var watch: WatchGuard
    /// Set when only part of the value was read (a string over 1 MiB): the shell shows it but refuses edits.
    public var partial: PartialLoad?
    /// Where "Load more" continues (an `HSCAN` cursor); nil once every element is loaded. Unlike `partial`, a paged
    /// collection stays editable: edits touch only loaded elements (03 → Value editors).
    public var next: Data?

    public init(rows: [EditorRow], watch: WatchGuard, partial: PartialLoad? = nil, next: Data? = nil) {
        self.rows = rows; self.watch = watch; self.partial = partial; self.next = next
    }
}

/// One more page of a paged collection: its rows and where the page after it starts (nil at the end).
public struct EditorPage: Sendable, Equatable {
    public var rows: [EditorRow]
    public var next: Data?

    public init(rows: [EditorRow], next: Data?) { self.rows = rows; self.next = next }
}

/// How much of a value an editor read, out of its full size (FR-ED01: "Partial (1 MiB of 2 MiB)").
public struct PartialLoad: Sendable, Equatable {
    public var loadedBytes: Int64
    public var totalBytes: Int64
    /// Whether "Load all" may read the rest: false when the whole value wouldn't fit one bounded reply.
    public var canLoadAll: Bool

    public init(loadedBytes: Int64, totalBytes: Int64, canLoadAll: Bool) {
        self.loadedBytes = loadedBytes; self.totalBytes = totalBytes; self.canLoadAll = canLoadAll
    }

    public var text: String { "Partial (\(Self.binary(loadedBytes)) of \(Self.binary(totalBytes)))" }

    /// "1 MiB", "2.5 MiB", "640 KiB": binary units, the way the limits are stated.
    static func binary(_ bytes: Int64) -> String {
        guard bytes >= 1_024 else { return "\(max(bytes, 0)) bytes" }
        var value = Double(bytes) / 1_024, unit = "KiB"
        for larger in ["MiB", "GiB"] where value >= 1_024 { value /= 1_024; unit = larger }
        // One decimal, dropped when whole, so the 1 MiB page reads "1 MiB" rather than "1.0 MiB".
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) \(unit)" : String(format: "%.1f %@", rounded, unit)
    }
}

/// How one type's editor (KEEL-029…034) loads and saves through the editor shell: the shell keeps the loaded rows and
/// the draft, counts the changes and runs the save; the binding knows the commands.
public struct EditorBinding: Sendable {
    public typealias Load = @Sendable (_ key: Data, DataCommandService, DataContext) async throws(DataCommandError) -> LoadedValue
    /// The writes that turn `loaded` into `draft`; empty when they are the same.
    public typealias Writes = @Sendable (_ key: Data, _ loaded: [EditorRow], _ draft: [EditorRow]) -> [DataOperation]

    /// The next page after `cursor` ("Load more").
    public typealias LoadMore = @Sendable (_ key: Data, _ cursor: Data, DataCommandService, DataContext) async throws(DataCommandError) -> EditorPage
    /// The guard of one save, when it depends on what changed (a hash guards each touched field).
    public typealias Guard = @Sendable (_ key: Data, _ loaded: [EditorRow], _ draft: [EditorRow]) -> WatchGuard
    /// The value as the server has it after a save (or a save with an unknown outcome).
    public typealias Reread =
        @Sendable (_ key: Data, _ loaded: LoadedValue, _ draft: [EditorRow], DataCommandService, DataContext) async throws(DataCommandError)
        -> LoadedValue

    public var load: Load
    public var writes: Writes
    /// "Load all" after a partial load: reads the whole value. Nil for types that never load partially.
    public var loadAll: Load?
    /// Nil for types that load whole.
    public var loadMore: LoadMore?
    /// Nil: saves are guarded by `LoadedValue.watch`, the reads made on load.
    public var saveGuard: Guard?
    /// Nil: the shell reads the value again with `loadAll`, else `load`. A paged collection re-reads only what it touched,
    /// so the pages already loaded stay.
    public var reread: Reread?

    public init(
        load: @escaping Load, writes: @escaping Writes, loadAll: Load? = nil, loadMore: LoadMore? = nil, saveGuard: Guard? = nil, reread: Reread? = nil
    ) {
        self.load = load; self.writes = writes; self.loadAll = loadAll; self.loadMore = loadMore; self.saveGuard = saveGuard; self.reread = reread
    }

    /// The editor for a core type; nil while its editor isn't built (the shell shows the header and a notice).
    public static func editor(for type: KeyType) -> EditorBinding? {
        switch type {
        case .string: return StringEditor.binding
        case .hash: return HashEditor.binding
        default: return nil
        }
    }
}

/// The reads editors share: one command on the browser connection, and the error for a reply of the wrong shape.
enum EditorReads {
    static func read(_ operation: DataOperation, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> RESPValue {
        try await service.execute(.operation(operation), origin: .editor, context: context).reply
    }

    static func integer(_ operation: DataOperation, _ service: DataCommandService, _ context: DataContext, type: String) async throws(DataCommandError) -> Int64 {
        let reply = try await read(operation, service, context)
        guard case .integer(let value) = reply else { throw unexpected(reply, type: type) }
        return value
    }

    /// A nil reply means the key went away after it was listed; a server error (`WRONGTYPE`, an ACL refusal) is shown as sent.
    static func unexpected(_ reply: RESPValue, type: String) -> DataCommandError {
        switch reply {
        case .error(let text), .blobError(let text): return .invalidRequest(String(decoding: text.prefix(512), as: UTF8.self))
        case _ where reply.isNull: return gone
        default: return .invalidRequest("The server sent an unexpected reply for a \(type).")
        }
    }

    static let gone = DataCommandError.invalidRequest("The key no longer exists.")
}

public enum EditorChanges {
    /// Rows added, changed or removed in `draft` compared with `loaded`: one unsaved change each.
    public static func changedRows(loaded: [EditorRow], draft: [EditorRow]) -> Set<Data> {
        let before = Dictionary(loaded.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(draft.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        var changed = Set(after.compactMap { id, value in before[id] == value ? nil : id })
        changed.formUnion(before.keys.filter { after[$0] == nil })
        return changed
    }
}

// MARK: - Header (FR-ED13)

/// The editor header's facts: type, expiry and length, read when the key opens.
public struct KeyHeader: Sendable, Equatable {
    public var type: KeyType
    /// `PTTL` as loaded: nil without an expiry (or when it couldn't be read).
    public var ttlMilliseconds: Int64?
    /// The type's element count (`HLEN`, …); nil for module types or when it couldn't be read.
    public var length: Int64?
    public var readOnly: Bool

    public init(type: KeyType, ttlMilliseconds: Int64? = nil, length: Int64? = nil, readOnly: Bool) {
        self.type = type; self.ttlMilliseconds = ttlMilliseconds; self.length = length; self.readOnly = readOnly
    }

    /// The one metadata line: "Expires in 3 days · 6 fields", "No expiry · 12 bytes · Read-only".
    public var metadataLine: String {
        var parts = [ttlMilliseconds.map { "Expires in " + Self.relative($0) } ?? "No expiry"]
        if let length, let command = LengthCommand(type) { parts.append(command.describe(length)) }
        if readOnly { parts.append("Read-only") }
        return parts.joined(separator: " · ")
    }

    /// The largest whole unit: "3 days", "1 hour", "45 seconds" (rounded up, like the key rows).
    static func relative(_ milliseconds: Int64) -> String {
        let seconds = max((milliseconds + 999) / 1_000, 1)
        let (count, unit): (Int64, String) =
            switch seconds {
            case 86_400...: (seconds / 86_400, "day")
            case 3_600...: (seconds / 3_600, "hour")
            case 60...: (seconds / 60, "minute")
            default: (seconds, "second")
            }
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// Reads `PTTL` and the length beside the type the browser already knows. A failed read leaves its part out
    /// rather than failing the editor: the header is informative only.
    public static func load(key: Data, type: KeyType, service: DataCommandService, context: DataContext) async -> KeyHeader {
        async let ttl = integer(.pttl(key: key), service, context)
        async let length = Self.length(of: key, type: type, service, context)
        let milliseconds = await ttl
        return KeyHeader(type: type, ttlMilliseconds: milliseconds.flatMap { $0 >= 0 ? $0 : nil }, length: await length, readOnly: context.profile.readOnly)
    }

    private static func length(of key: Data, type: KeyType, _ service: DataCommandService, _ context: DataContext) async -> Int64? {
        guard let command = LengthCommand(type) else { return nil }
        return await integer(.length(key: key, command: command), service, context)
    }
}

/// An integer reply, or nil for anything else (a server error, a refusal, a lost connection).
private func integer(_ operation: DataOperation, _ service: DataCommandService, _ context: DataContext) async -> Int64? {
    guard case .integer(let value)? = try? await service.execute(.operation(operation), origin: .editor, context: context).reply else { return nil }
    return value
}

// MARK: - Details (FR-ED13)

/// ⋯ → Details: encoding, exact TTL and, on request, memory size. Anything the server can't or won't answer (no
/// `OBJECT` on Dragonfly, an ACL without it, the key gone) is "unavailable", never an error.
public struct KeyDetails: Sendable, Equatable {
    public enum Value<T: Sendable & Equatable>: Sendable, Equatable {
        case value(T)
        case unavailable
        /// Not asked yet (memory size waits for the user).
        case notLoaded
    }

    public enum TTL: Sendable, Equatable { case persistent, milliseconds(Int64) }

    public var encoding: Value<String>
    public var ttl: Value<TTL>
    public var memory: Value<Int64>

    public init(encoding: Value<String> = .notLoaded, ttl: Value<TTL> = .notLoaded, memory: Value<Int64> = .notLoaded) {
        self.encoding = encoding; self.ttl = ttl; self.memory = memory
    }

    public static let unavailableText = "unavailable"

    public var encodingText: String {
        if case .value(let text) = encoding { return text }
        return encoding == .notLoaded ? "…" : Self.unavailableText
    }

    /// "No expiry", "90,000 ms (1m 30s)".
    public var ttlText: String {
        switch ttl {
        case .value(.persistent): return "No expiry"
        case .value(.milliseconds(let ms)): return "\(KeyIndexFooter.grouped(Int(clamping: ms))) ms (\(TTLFormatter.short(milliseconds: ms)))"
        case .unavailable: return Self.unavailableText
        case .notLoaded: return "…"
        }
    }

    /// "4.1 KB (4,213 bytes)"; nil until measured.
    public var memoryText: String? {
        switch memory {
        case .value(let bytes): return "\(KeySizeFormatter.short(bytes: bytes)) (\(KeyIndexFooter.grouped(Int(clamping: bytes))) bytes)"
        case .unavailable: return Self.unavailableText
        case .notLoaded: return nil
        }
    }

    /// Encoding and exact TTL; `memory` adds `MEMORY USAGE`, which the user asks for (it can be slow on big values).
    public static func load(key: Data, memory: Bool, service: DataCommandService, context: DataContext) async -> KeyDetails {
        async let encoding = reply(.objectEncoding(key: key), service, context)
        async let ttl = reply(.pttl(key: key), service, context)
        async let size = memory ? reply(.memoryUsage(key: key), service, context) : nil
        var details = KeyDetails()
        switch await encoding {
        case .bulkString(let name)?, .simpleString(let name)?: details.encoding = .value(String(decoding: name, as: UTF8.self))
        default: details.encoding = .unavailable
        }
        switch await ttl {
        case .integer(-1)?: details.ttl = .value(.persistent)
        case .integer(let ms)? where ms >= 0: details.ttl = .value(.milliseconds(ms))
        // -2 (the key is gone), an error or no reply.
        default: details.ttl = .unavailable
        }
        if memory {
            if case .integer(let bytes)? = await size { details.memory = .value(bytes) } else { details.memory = .unavailable }
        }
        return details
    }
}

/// The reply, or nil when the command was refused or the connection failed. Server errors come back as values.
private func reply(_ operation: DataOperation, _ service: DataCommandService, _ context: DataContext) async -> RESPValue? {
    try? await service.execute(.operation(operation), origin: .editor, context: context).reply
}

import Foundation
import KeelRESP

/// The stream viewer (FR-ED06): one row per entry, named by its ID, whose value holds the entry's field/value pairs
/// (`StreamEditor.encode`). Entries load in pages of 500 with `XREVRANGE` (newest first, the default) or `XRANGE`; a
/// page starts right after the last entry loaded, with an exclusive range where the server has it (6.2+) or the next
/// possible ID on 6.0 / 6.1, so paging never repeats or skips an entry. Entries are read-only: the draft never changes
/// and nothing is saved (`XDEL` is P1). "Add entry" runs `XADD` at once.
public enum StreamEditor {
    /// Entries per page (`COUNT`).
    public static let pageSize = 500

    public static let binding = EditorBinding(load: load, writes: writes, loadMore: loadMore, editsValues: false)

    // MARK: - Entries

    /// `ms-seq` as two numbers; nil for anything else. Digits only: `UInt64("+1")` would accept a sign Redis rejects.
    public static func parseID(_ id: Data) -> (ms: UInt64, seq: UInt64)? {
        let parts = String(decoding: id, as: UTF8.self).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }), let ms = UInt64(parts[0]), let seq = UInt64(parts[1])
        else { return nil }
        return (ms, seq)
    }

    /// Stream order: by milliseconds, then sequence. IDs that don't parse (never from a server) sort by bytes, last.
    public static func precedes(_ a: Data, _ b: Data) -> Bool {
        switch (parseID(a), parseID(b)) {
        case (let x?, let y?): return x.ms != y.ms ? x.ms < y.ms : x.seq < y.seq
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.lexicographicallyPrecedes(b)
        }
    }

    /// An entry's fields packed into one row value, byte for byte: `<length>:<bytes>` per field and per value.
    public static func encode(_ fields: [DataOperation.FieldValue]) -> Data {
        var data = Data()
        for part in fields.flatMap({ [$0.field, $0.value] }) { data += Data("\(part.count):".utf8) + part }
        return data
    }

    /// The fields `encode` packed; nil for bytes it didn't make.
    public static func fields(of row: EditorRow) -> [DataOperation.FieldValue]? {
        var parts: [Data] = [], rest = row.value[...]
        while !rest.isEmpty {
            guard let colon = rest.firstIndex(of: UInt8(ascii: ":")), let length = Int(String(decoding: rest[..<colon], as: UTF8.self)), length >= 0 else { return nil }
            let start = rest.index(after: colon)
            guard rest.distance(from: start, to: rest.endIndex) >= length else { return nil }
            let end = rest.index(start, offsetBy: length)
            parts.append(Data(rest[start..<end]))
            rest = rest[end...]
        }
        guard parts.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: parts.count, by: 2).map { DataOperation.FieldValue(field: parts[$0], value: parts[$0 + 1]) }
    }

    public static func row(_ id: Data, fields: [DataOperation.FieldValue]) -> EditorRow { EditorRow(id: id, value: encode(fields)) }

    // MARK: - Paging

    /// Where the next page starts: the last entry loaded and the direction. Encoded as the opaque "Load more" cursor.
    public struct Cursor: Sendable, Equatable {
        public var descending: Bool
        public var lastID: Data

        public init(descending: Bool, lastID: Data) { self.descending = descending; self.lastID = lastID }

        /// "d 1700000000000-5" / "a 0-1": direction and the last ID loaded.
        public var data: Data { Data("\(descending ? "d" : "a") ".utf8) + lastID }

        public init?(_ data: Data) {
            guard data.count > 2, data.first == UInt8(ascii: "a") || data.first == UInt8(ascii: "d"), data[data.startIndex + 1] == UInt8(ascii: " ") else { return nil }
            let id = Data(data.dropFirst(2))
            guard parseID(id) != nil else { return nil }
            self.init(descending: data.first == UInt8(ascii: "d"), lastID: id)
        }
    }

    /// The first page, newest first (FR-ED06); Reload, and the read-back after an add, come here too.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        try await load(key: key, descending: true, service: service, context: context)
    }

    /// The first page, oldest first without `descending`. A stream with no entries still exists (`XADD`, then `XDEL`),
    /// so an empty page is an empty stream unless `XLEN`'s key is gone, which the header shows.
    public static func load(key: Data, descending: Bool, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let first: Data = descending ? Data("+".utf8) : Data("-".utf8), last: Data = descending ? Data("-".utf8) : Data("+".utf8)
        let page = try await range(key, .streamRange(key: key, from: first, to: last, count: pageSize, reverse: descending), descending: descending, service, context)
        // Nothing is ever saved, so there is nothing to guard.
        return LoadedValue(rows: page.rows, watch: WatchGuard(key: key, reads: [], expected: []), next: page.next)
    }

    /// "Load more": the page after the cursor's entry, in the cursor's direction.
    @Sendable public static func loadMore(key: Data, cursor: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> EditorPage {
        guard let cursor = Cursor(cursor) else { throw .invalidRequest("The stream's page position is not valid.") }
        let exclusive = await service.supports(.xrangeExclusive, context: context)
        // Nothing can follow the smallest or largest possible ID.
        guard let operation = pageOperation(key: key, after: cursor, exclusive: exclusive) else { return EditorPage(rows: [], next: nil) }
        return try await range(key, operation, descending: cursor.descending, service, context)
    }

    /// The page after `cursor` (AC1): `(lastID` where exclusive ranges are probed available (6.2+), else the next
    /// possible ID past it as an inclusive bound (`ms-(seq±1)`, crossing into the neighbouring millisecond when the
    /// sequence runs out). Nil when no ID lies beyond the cursor.
    public static func pageOperation(key: Data, after cursor: Cursor, exclusive: Bool) -> DataOperation? {
        guard let start = bound(after: cursor.lastID, descending: cursor.descending, exclusive: exclusive) else { return nil }
        return .streamRange(key: key, from: start, to: Data((cursor.descending ? "-" : "+").utf8), count: pageSize, reverse: cursor.descending)
    }

    /// The first ID of the next page, as `XRANGE` / `XREVRANGE` spell a bound.
    public static func bound(after id: Data, descending: Bool, exclusive: Bool) -> Data? {
        guard let (ms, seq) = parseID(id) else { return nil }
        if exclusive {
            // `(0-0` going down, or `(max-max` going up, would be an empty range Redis refuses as invalid.
            if descending ? (ms == 0 && seq == 0) : (ms == .max && seq == .max) { return nil }
            return Data("(".utf8) + id
        }
        if descending {
            if seq > 0 { return Data("\(ms)-\(seq - 1)".utf8) }
            // Sequence 0: the previous ID is the last one of the millisecond before.
            return ms > 0 ? Data("\(ms - 1)-\(UInt64.max)".utf8) : nil
        }
        if seq < .max { return Data("\(ms)-\(seq + 1)".utf8) }
        // Sequence exhausted: the next ID is the first one of the following millisecond.
        return ms < .max ? Data("\(ms + 1)-0".utf8) : nil
    }

    private static func range(_ key: Data, _ operation: DataOperation, descending: Bool, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        let reply = try await EditorReads.read(operation, service, context)
        guard let rows = entries(reply) else { throw EditorReads.unexpected(reply, type: "stream") }
        // A short page is the end; a full one continues after its last entry.
        let next = rows.count >= pageSize ? rows.last.map { Cursor(descending: descending, lastID: $0.id).data } : nil
        return EditorPage(rows: rows, next: next)
    }

    // MARK: - Read-only (AC3)

    /// Entries are never edited in v1, so a save writes nothing.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] { [] }

    // MARK: - Add entry

    /// The ID Redis assigns: `*`.
    public static let autoID = Data("*".utf8)

    /// "Add entry": one `XADD key id field value …`, run at once. `id` is `*` (the server assigns it) or what the user
    /// typed, which the server checks (it must be greater than the stream's last ID).
    public static func add(id: Data, fields: [DataOperation.FieldValue], key: Data) -> [DataOperation] {
        [.streamAdd(key: key, id: id, fields: fields)]
    }

    /// The new entry's ID from `EXEC`'s replies for `add`; nil for anything else.
    public static func addedID(_ reply: RESPValue) -> Data? {
        guard case .array(let replies) = reply, let first = replies.first else { return nil }
        switch first {
        case .bulkString(let id), .simpleString(let id): return parseID(id) != nil ? id : nil
        default: return nil
        }
    }

    // MARK: - Replies

    /// `XRANGE` / `XREVRANGE` entries: `[id, [field, value, …]]` each (a RESP3 server may send the fields as a map).
    static func entries(_ reply: RESPValue) -> [EditorRow]? {
        guard case .array(let items) = reply else { return nil }
        var rows: [EditorRow] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard case .array(let entry) = item, entry.count == 2, case .bulkString(let id) = entry[0], let fields = fieldValues(entry[1]) else { return nil }
            rows.append(row(id, fields: fields))
        }
        return rows
    }

    private static func fieldValues(_ reply: RESPValue) -> [DataOperation.FieldValue]? {
        let flat: [RESPValue]
        switch reply {
        case .array(let items): flat = items
        case .map(let pairs): flat = pairs.flatMap { [$0.key, $0.value] }
        // An entry whose fields were all trimmed away answers nil in some versions.
        case _ where reply.isNull: return []
        default: return nil
        }
        guard flat.count.isMultiple(of: 2) else { return nil }
        var fields: [DataOperation.FieldValue] = []
        for index in stride(from: 0, to: flat.count, by: 2) {
            guard case .bulkString(let field) = flat[index], case .bulkString(let value) = flat[index + 1] else { return nil }
            fields.append(DataOperation.FieldValue(field: field, value: value))
        }
        return fields
    }
}

// MARK: - Details (FR-ED06)

/// `XINFO STREAM`'s summary for ⋯ → Details: length, first and last entry IDs, consumer groups.
public struct StreamSummary: Sendable, Equatable {
    public var length: Int64
    /// Nil for an empty stream.
    public var firstID: Data?
    public var lastID: Data?
    public var groups: Int64

    public init(length: Int64, firstID: Data?, lastID: Data?, groups: Int64) { self.length = length; self.firstID = firstID; self.lastID = lastID; self.groups = groups }

    /// RESP2's flat `name, value, …` array or RESP3's map; nil when `length` or `groups` is missing.
    public init?(_ reply: RESPValue) {
        var fields: [String: RESPValue] = [:]
        switch reply {
        case .array(let items) where items.count.isMultiple(of: 2):
            for index in stride(from: 0, to: items.count, by: 2) { if let name = Self.name(items[index]) { fields[name] = items[index + 1] } }
        case .map(let pairs):
            for pair in pairs { if let name = Self.name(pair.key) { fields[name] = pair.value } }
        default: return nil
        }
        guard case .integer(let length)? = fields["length"], case .integer(let groups)? = fields["groups"] else { return nil }
        self.init(length: length, firstID: fields["first-entry"].flatMap(Self.entryID), lastID: fields["last-entry"].flatMap(Self.entryID), groups: groups)
    }

    private static func name(_ value: RESPValue) -> String? {
        switch value {
        case .bulkString(let text), .simpleString(let text): return String(decoding: text, as: UTF8.self)
        default: return nil
        }
    }

    /// `first-entry` / `last-entry`: `[id, [fields]]`, or nil for an empty stream.
    private static func entryID(_ value: RESPValue) -> Data? {
        guard case .array(let entry) = value, case .bulkString(let id)? = entry.first else { return nil }
        return id
    }
}

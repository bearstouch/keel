import Foundation
import KeelRESP

/// The hash editor (FR-ED02): one row per field. Hashes of up to 1,000 fields load with `HGETALL`; larger ones page
/// with `HSCAN … COUNT 500` and "Load more", and edits touch only loaded fields. A save sends `HSET` per added or changed
/// field and one `HDEL` for removed fields inside the shell's `WATCH` + `MULTI/EXEC`, so a rename (HSET new + HDEL old)
/// is all or nothing. Each touched field is guarded by its loaded value, never the whole hash.
public enum HashEditor {
    /// The largest hash read whole with `HGETALL`.
    public static let fullLoadLimit: Int64 = 1_000
    /// `HSCAN`'s COUNT, and how many fields a page aims for.
    public static let pageSize = 500
    /// `HSCAN` may answer a round with few or no fields; a page stops after this many rounds so it stays quick.
    static let scanRounds = 8
    /// `HSCAN`'s first cursor, and the one it returns once the scan is complete.
    private static let startCursor = Data("0".utf8)

    public static let binding = EditorBinding(load: load, writes: writes, loadMore: loadMore, saveGuard: saveGuard, reread: reread)

    /// `HLEN` first, so a large hash is never read whole: up to 1,000 fields `HGETALL`, else the first `HSCAN` page.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let length = try await EditorReads.integer(.length(key: key, command: .hlen), service, context, type: "hash")
        // A hash is never empty: no fields means no key.
        guard length > 0 else { throw EditorReads.gone }
        // The guard is per save (`saveGuard`), built from the fields it touches.
        let watch = WatchGuard(key: key, reads: [], expected: [])
        guard length > fullLoadLimit else {
            let reply = try await EditorReads.read(.hashGetAll(key: key), service, context)
            guard let rows = fields(reply) else { throw EditorReads.unexpected(reply, type: "hash") }
            guard !rows.isEmpty else { throw EditorReads.gone }
            return LoadedValue(rows: rows, watch: watch)
        }
        let page = try await scan(key, from: startCursor, service, context)
        return LoadedValue(rows: page.rows, watch: watch, next: page.next)
    }

    /// "Load more": the page after `cursor`.
    @Sendable public static func loadMore(key: Data, cursor: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        try await scan(key, from: cursor, service, context)
    }

    /// `HSET` for each added or changed field (draft order), then one `HDEL` for the removed ones. A rename is the pair.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] {
        let before = values(loaded), after = values(draft)
        let sets = draft.filter { before[$0.id] != $0.value }.map { DataOperation.hashSetField(key: key, field: $0.id, value: $0.value) }
        let removed = loaded.map(\.id).filter { after[$0] == nil }
        return sets + (removed.isEmpty ? [] : [.hashDeleteFields(key: key, fields: removed)])
    }

    /// `HGET` of every touched field must still give its loaded value (a field added in the draft must still be absent),
    /// so a field changed elsewhere is a `CONFLICT` while changes to other fields don't block the save.
    @Sendable public static func saveGuard(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> WatchGuard {
        let before = values(loaded)
        let touched = touchedFields(loaded: loaded, draft: draft)
        return WatchGuard(
            key: key, reads: touched.map { .hashGet(key: key, field: $0) },
            expected: touched.map { before[$0].map(RESPValue.bulkString) ?? .nullBulkString })
    }

    /// After a save: the touched fields as the server has them now, the rest (and the pages loaded) as they were.
    @Sendable public static func reread(key: Data, loaded: LoadedValue, draft: [EditorRow], service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> LoadedValue
    {
        var value = loaded
        for field in touchedFields(loaded: loaded.rows, draft: draft) {
            let row = try await serverField(key: key, field: field, service: service, context: context)
            if let index = value.rows.firstIndex(where: { $0.id == field }) {
                if let row { value.rows[index] = row } else { value.rows.remove(at: index) }
            } else if let row {
                value.rows.append(row)
            }
        }
        return value
    }

    /// One field as the server has it now (`HGET`); nil when it doesn't exist. Before adding or renaming onto a field
    /// that isn't loaded, the editor asks the server, so an unloaded field is never overwritten without asking.
    public static func serverField(key: Data, field: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> EditorRow? {
        let reply = try await EditorReads.read(.hashGet(key: key, field: field), service, context)
        if reply.isNull { return nil }
        guard case .bulkString(let value) = reply else { throw EditorReads.unexpected(reply, type: "hash") }
        return EditorRow(id: field, value: value)
    }

    // MARK: - Draft edits

    /// What an add or rename does to the draft.
    public enum Edit: Sendable, Equatable {
        case applied([EditorRow])
        /// The target field exists: the user confirms before it is overwritten (FR-ED02), then the edit runs with `overwrite`.
        case confirmOverwrite(field: Data)
        case refused(String)
    }

    static let emptyName = "A field name can't be empty."

    /// "+ Add field": a new field at the end, or (confirmed) a new value for an existing one.
    public static func add(field: Data, value: Data, to draft: [EditorRow], overwrite: Bool) -> Edit {
        guard !field.isEmpty else { return .refused(emptyName) }
        guard let index = draft.firstIndex(where: { $0.id == field }) else { return .applied(draft + [EditorRow(id: field, value: value)]) }
        guard overwrite else { return .confirmOverwrite(field: field) }
        var rows = draft
        rows[index].value = value
        return .applied(rows)
    }

    /// Rename: the value moves to `newField` in the old field's place; onto an existing field only when confirmed.
    public static func rename(_ field: Data, to newField: Data, in draft: [EditorRow], overwrite: Bool) -> Edit {
        guard !newField.isEmpty else { return .refused(emptyName) }
        guard let index = draft.firstIndex(where: { $0.id == field }) else { return .refused("The field is no longer in the table.") }
        guard newField != field else { return .applied(draft) }
        let existing = draft.firstIndex { $0.id == newField }
        if existing != nil, !overwrite { return .confirmOverwrite(field: newField) }
        var rows = draft
        rows[index].id = newField
        if let existing { rows.remove(at: existing) }
        return .applied(rows)
    }

    public static func delete(_ field: Data, from draft: [EditorRow]) -> [EditorRow] { draft.filter { $0.id != field } }

    // MARK: - Replies

    /// Pages until about `pageSize` fields or the end; fields `HSCAN` repeats within the page are kept once.
    private static func scan(_ key: Data, from start: Data, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> EditorPage {
        var rows: [EditorRow] = [], seen = Set<Data>(), cursor = start
        for _ in 0..<scanRounds {
            let reply = try await EditorReads.read(.hashScan(key: key, cursor: cursor, count: pageSize), service, context)
            guard case .array(let parts) = reply, parts.count == 2, case .bulkString(let next) = parts[0], let page = fields(parts[1]) else {
                throw EditorReads.unexpected(reply, type: "hash")
            }
            rows += page.filter { seen.insert($0.id).inserted }
            cursor = next
            if cursor == startCursor || rows.count >= pageSize { break }
        }
        return EditorPage(rows: rows, next: cursor == startCursor ? nil : cursor)
    }

    /// Field/value pairs: a flat array (RESP2, and `HSCAN`'s page) or a map (`HGETALL` over RESP3).
    static func fields(_ reply: RESPValue) -> [EditorRow]? {
        let pairs: [(RESPValue, RESPValue)]
        switch reply {
        case .array(let items) where items.count.isMultiple(of: 2):
            pairs = stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
        case .map(let entries): pairs = entries.map { ($0.key, $0.value) }
        default: return nil
        }
        var rows: [EditorRow] = []
        rows.reserveCapacity(pairs.count)
        for (field, value) in pairs {
            guard case .bulkString(let name) = field, case .bulkString(let bytes) = value else { return nil }
            rows.append(EditorRow(id: name, value: bytes))
        }
        return rows
    }

    private static func values(_ rows: [EditorRow]) -> [Data: Data] { Dictionary(rows.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first }) }

    /// Fields added, changed or removed, in a stable order: loaded order, then fields new in the draft.
    private static func touchedFields(loaded: [EditorRow], draft: [EditorRow]) -> [Data] {
        let changed = EditorChanges.changedRows(loaded: loaded, draft: draft)
        var seen = Set<Data>()
        return (loaded + draft).map(\.id).filter { changed.contains($0) && seen.insert($0).inserted }
    }
}

import Foundation
import KeelRESP

/// The list editor (FR-ED03): an indexed table read in `LRANGE` pages of 500 from any index ("Jump to index"), so a
/// loaded window is always contiguous. A row's id is its index (decimal digits). Edits by index go through the shell's
/// draft: a changed item is `LSET`, a deleted one is `LSET` to a unique sentinel + `LREM key 1 sentinel`, all in the
/// shell's `WATCH` + `MULTI/EXEC`, guarded by an `LRANGE` of the touched span so any shift of indexes is a `CONFLICT`.
/// Push, pop and insert change every index after them, so they run at once (`ListAction`) instead of through the draft.
public enum ListEditor {
    /// Items per `LRANGE` page.
    public static let pageSize = 500

    public static let binding = EditorBinding(load: load, writes: writes, loadMore: loadMore, saveGuard: saveGuard, reread: reread, positional: true)

    /// The row id of the item at `index`.
    public static func rowID(_ index: Int) -> Data { Data(String(index).utf8) }
    /// The index a row id names; nil for anything that isn't one.
    public static func index(of id: Data) -> Int? { Int(String(decoding: id, as: UTF8.self)) }

    // MARK: - Loading

    /// The first page.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        try await load(key: key, from: 0, service: service, context: context)
    }

    /// "Jump to index": the page starting at `start`. `LLEN` first, so an index past the end is refused with the length.
    public static func load(key: Data, from start: Int, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let length = try await EditorReads.integer(.length(key: key, command: .llen), service, context, type: "list")
        // A list is never empty: no items means no key.
        guard length > 0 else { throw EditorReads.gone }
        guard start >= 0, Int64(start) < length else {
            throw .invalidRequest("The list has \(LengthCommand.llen.describe(length)); indexes run from 0 to \(KeyIndexFooter.grouped(Int(clamping: length - 1))).")
        }
        let page = try await window(key, start: start, count: pageSize, service, context)
        return LoadedValue(rows: page.rows, watch: WatchGuard(key: key, reads: [], expected: []), next: page.next)
    }

    /// "Load more": the page starting at `cursor` (an index).
    @Sendable public static func loadMore(key: Data, cursor: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        guard let start = index(of: cursor), start >= 0 else { throw .invalidRequest("The next page's index isn't valid.") }
        return try await window(key, start: start, count: pageSize, service, context)
    }

    /// After a save or an action: the same window again (it may have shifted), or the first page when the list now
    /// ends before it. An empty first page means the last item went, and with it the key.
    @Sendable public static func reread(key: Data, loaded: LoadedValue, draft: [EditorRow], service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> LoadedValue
    {
        let start = loaded.rows.first.flatMap { index(of: $0.id) } ?? 0
        var page = try await window(key, start: start, count: max(loaded.rows.count, pageSize), service, context)
        if page.rows.isEmpty, start > 0 { page = try await window(key, start: 0, count: pageSize, service, context) }
        return LoadedValue(rows: page.rows, watch: loaded.watch, next: page.next)
    }

    /// `LRANGE start start+count`: one item more than the page, which tells whether more follow without `LLEN`.
    private static func window(_ key: Data, start: Int, count: Int, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        let reply = try await EditorReads.read(.listRange(key: key, start: start, stop: start + count), service, context)
        guard let values = items(reply) else { throw EditorReads.unexpected(reply, type: "list") }
        let rows = values.prefix(count).enumerated().map { EditorRow(id: rowID(start + $0.offset), value: $0.element) }
        return EditorPage(rows: rows, next: values.count > count ? rowID(start + count) : nil)
    }

    /// `LRANGE`'s items (an array on RESP2 and RESP3).
    static func items(_ reply: RESPValue) -> [Data]? {
        guard case .array(let parts) = reply else { return nil }
        var values: [Data] = []
        values.reserveCapacity(parts.count)
        for part in parts {
            guard case .bulkString(let bytes) = part else { return nil }
            values.append(bytes)
        }
        return values
    }

    // MARK: - Saving the draft

    /// `LSET` for each changed item; for each deleted one `LSET` to its own sentinel, then `LREM 1` of each sentinel. Every
    /// `LSET` runs before the first `LREM`, so the indexes they name are still the loaded ones.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] {
        let after = Dictionary(draft.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        var sets: [DataOperation] = [], removed: [Int] = []
        for row in loaded {
            guard let index = index(of: row.id) else { continue }
            if let value = after[row.id] {
                if value != row.value { sets.append(.listSet(key: key, index: index, value: value)) }
            } else {
                removed.append(index)
            }
        }
        let marked = removed.map { (index: $0, sentinel: sentinel()) }
        return sets + marked.map { .listSet(key: key, index: $0.index, value: $0.sentinel) } + marked.map { .listRemove(key: key, count: 1, value: $0.sentinel) }
    }

    /// The touched span (first to last changed or deleted index) must still read as loaded: an item pushed, popped or
    /// removed elsewhere shifts the span and the save is a `CONFLICT`, while changes outside it don't block it.
    @Sendable public static func saveGuard(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> WatchGuard {
        let touched = EditorChanges.changedRows(loaded: loaded, draft: draft).compactMap(index(of:))
        guard let low = touched.min(), let high = touched.max() else { return WatchGuard(key: key, reads: [], expected: []) }
        return span(key: key, low...high, in: loaded)
    }

    /// A delete's placeholder: never a value a user stores, and new for every item deleted, so `LREM 1` removes exactly
    /// the item it replaced even when another save's sentinel were somehow still in the list.
    static func sentinel() -> Data {
        var bytes = Data("\u{0}keel-delete:".utf8)
        bytes.append(Data(UUID().uuidString.utf8))
        return bytes
    }

    /// `LRANGE` of `indexes` expecting the loaded items. A loaded window has no gaps; if `indexes` reach past it the
    /// guard falls back to each loaded index on its own.
    private static func span(key: Data, _ indexes: ClosedRange<Int>, in loaded: [EditorRow]) -> WatchGuard {
        let byIndex = Dictionary(loaded.compactMap { row in index(of: row.id).map { ($0, row.value) } }, uniquingKeysWith: { first, _ in first })
        let values = indexes.compactMap { byIndex[$0] }
        if values.count == indexes.count {
            return WatchGuard(
                key: key, reads: [.listRange(key: key, start: indexes.lowerBound, stop: indexes.upperBound)], expected: [.array(values.map(RESPValue.bulkString))])
        }
        let known = indexes.compactMap { index in byIndex[index].map { (index: index, value: $0) } }
        return WatchGuard(
            key: key, reads: known.map { .listRange(key: key, start: $0.index, stop: $0.index) }, expected: known.map { .array([.bulkString($0.value)]) })
    }

    // MARK: - Actions

    /// Pop and push at either end, and insert before or after an item: writes that run at once in one transaction, with
    /// the guard that proves the item the user acted on is still where the table shows it.
    public struct Action: Sendable, Equatable {
        public var writes: [DataOperation]
        /// Nil: nothing the user saw is assumed (a push, or a pop at an end that isn't loaded).
        public var watch: WatchGuard?

        public init(writes: [DataOperation], watch: WatchGuard?) { self.writes = writes; self.watch = watch }
    }

    /// `LPUSH` / `RPUSH` one item.
    public static func push(_ value: Data, key: Data, atHead: Bool) -> Action {
        Action(writes: [.listPush(key: key, values: [value], atHead: atHead)], watch: nil)
    }

    /// `LPOP` / `RPOP`. When the loaded window holds that end, the pop is guarded by it, so it removes the item shown.
    public static func pop(key: Data, atHead: Bool, loaded: LoadedValue) -> Action {
        let write = DataOperation.listPop(key: key, atHead: atHead)
        // The head is loaded when the window starts at index 0; the tail when no page follows it.
        let end: EditorRow?, at: Int
        if atHead {
            end = loaded.rows.first.flatMap { index(of: $0.id) == 0 ? $0 : nil }; at = 0
        } else {
            end = loaded.next == nil ? loaded.rows.last : nil; at = -1
        }
        guard let end else { return Action(writes: [write], watch: nil) }
        return Action(writes: [write], watch: WatchGuard(key: key, reads: [.listRange(key: key, start: at, stop: at)], expected: [.array([.bulkString(end.value)])]))
    }

    /// Pops ask first on production profiles (a normal confirmation, not a typed one).
    public static func popNeedsConfirmation(_ profile: SafetyProfile) -> Bool { profile.production }

    /// Insert `value` before or after the item at `index`. `LINSERT` places by value (the first match), so the item is
    /// swapped for a unique sentinel to pivot on and then put back: the new item lands at the index, never beside an
    /// earlier copy of the same value. Nil when `index` isn't loaded.
    public static func insert(_ value: Data, key: Data, at index: Int, before: Bool, loaded: [EditorRow]) -> Action? {
        guard let item = loaded.first(where: { Self.index(of: $0.id) == index }) else { return nil }
        let pivot = sentinel()
        return Action(
            writes: [
                .listSet(key: key, index: index, value: pivot), .listInsert(key: key, before: before, pivot: pivot, value: value),
                // Inserting before moves the pivot one place on.
                .listSet(key: key, index: before ? index + 1 : index, value: item.value)
            ],
            watch: span(key: key, index...index, in: loaded))
    }
}

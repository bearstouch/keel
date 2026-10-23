import Foundation
import KeelRESP

/// The set editor (FR-ED04): one row per member, named by the member's bytes (its value is the same bytes). Sets of up
/// to 1,000 members load with `SMEMBERS`; larger ones page with `SSCAN … COUNT 500` and "Load more". Adding runs at once
/// (`SADD`), so its reply says whether the member was new; removing is a draft change the save sends as one `SREM` inside
/// the shell's `WATCH` + `MULTI/EXEC`.
public enum SetEditor {
    /// The largest set read whole with `SMEMBERS`.
    public static let fullLoadLimit: Int64 = 1_000
    /// `SSCAN`'s COUNT, and how many members a page aims for.
    public static let pageSize = 500
    /// `SSCAN` may answer a round with few or no members; a page stops after this many rounds so it stays quick.
    static let scanRounds = 8
    /// `SSCAN`'s first cursor, and the one it returns once the scan is complete.
    private static let startCursor = Data("0".utf8)

    public static let binding = EditorBinding(load: load, writes: writes, loadMore: loadMore, reread: reread, editsValues: false)

    /// `SCARD` first, so a large set is never read whole: up to 1,000 members `SMEMBERS`, else the first `SSCAN` page.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let count = try await EditorReads.integer(.length(key: key, command: .scard), service, context, type: "set")
        // A set is never empty: no members means no key.
        guard count > 0 else { throw EditorReads.gone }
        // Removing a member that is already gone is harmless, so the guard is the key alone (no reads to compare).
        let watch = WatchGuard(key: key, reads: [], expected: [])
        guard count > fullLoadLimit else {
            let reply = try await EditorReads.read(.setMembers(key: key), service, context)
            guard let rows = members(reply) else { throw EditorReads.unexpected(reply, type: "set") }
            guard !rows.isEmpty else { throw EditorReads.gone }
            return LoadedValue(rows: rows, watch: watch)
        }
        let page = try await scan(key, from: startCursor, service, context)
        // A complete scan with no members: the key went away between `SCARD` and `SSCAN`.
        guard !page.rows.isEmpty || page.next != nil else { throw EditorReads.gone }
        return LoadedValue(rows: page.rows, watch: watch, next: page.next)
    }

    /// "Load more": the page after `cursor`.
    @Sendable public static func loadMore(key: Data, cursor: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        try await scan(key, from: cursor, service, context)
    }

    /// One `SREM` of the members removed from the draft. Members are only ever added at once (`add`), never in the draft.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] {
        let removed = removedMembers(loaded: loaded, draft: draft)
        return removed.isEmpty ? [] : [.setRemove(key: key, members: removed)]
    }

    /// After a save: each removed member is asked about (`SISMEMBER`) and leaves the rows once gone; the pages loaded stay.
    @Sendable public static func reread(key: Data, loaded: LoadedValue, draft: [EditorRow], service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> LoadedValue
    {
        var gone = Set<Data>()
        for member in removedMembers(loaded: loaded.rows, draft: draft) {
            let present = try await EditorReads.integer(.setIsMember(key: key, member: member), service, context, type: "set")
            if present == 0 { gone.insert(member) }
        }
        var value = loaded
        value.rows.removeAll { gone.contains($0.id) }
        return value
    }

    // MARK: - Adding

    /// "+ Add member": `SADD` of one member, run at once.
    public static func add(_ member: Data, key: Data) -> [DataOperation] { [.setAdd(key: key, members: [member])] }

    /// What `SADD` did, read from the transaction's replies.
    public enum AddOutcome: Sendable, Equatable {
        case added
        /// `SADD` returned 0: the member was in the set already (FR-ED04).
        case alreadyMember
    }

    public static let alreadyMemberText = "Already a member of this set."

    /// `EXEC`'s replies for `add`: `[1]` added, `[0]` already a member; nil for anything else.
    public static func addOutcome(_ reply: RESPValue) -> AddOutcome? {
        guard case .array(let replies) = reply, case .integer(let added)? = replies.first else { return nil }
        return added == 0 ? .alreadyMember : .added
    }

    public static func row(_ member: Data) -> EditorRow { EditorRow(id: member, value: member) }

    // MARK: - Replies

    /// Pages until about `pageSize` members or the end; members `SSCAN` repeats within the page are kept once.
    private static func scan(_ key: Data, from start: Data, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> EditorPage {
        var rows: [EditorRow] = [], seen = Set<Data>(), cursor = start
        for _ in 0..<scanRounds {
            let reply = try await EditorReads.read(.setScan(key: key, cursor: cursor, count: pageSize), service, context)
            guard case .array(let parts) = reply, parts.count == 2, case .bulkString(let next) = parts[0], let page = members(parts[1]) else {
                throw EditorReads.unexpected(reply, type: "set")
            }
            rows += page.filter { seen.insert($0.id).inserted }
            cursor = next
            if cursor == startCursor || rows.count >= pageSize { break }
        }
        return EditorPage(rows: rows, next: cursor == startCursor ? nil : cursor)
    }

    /// Members: an array (RESP2, and `SSCAN`'s page) or a set (`SMEMBERS` over RESP3).
    static func members(_ reply: RESPValue) -> [EditorRow]? {
        let items: [RESPValue]
        switch reply {
        case .array(let values), .set(let values): items = values
        default: return nil
        }
        var rows: [EditorRow] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard case .bulkString(let member) = item else { return nil }
            rows.append(row(member))
        }
        return rows
    }

    /// Loaded members missing from the draft, in loaded order.
    private static func removedMembers(loaded: [EditorRow], draft: [EditorRow]) -> [Data] {
        let kept = Set(draft.map(\.id))
        return loaded.map(\.id).filter { !kept.contains($0) }
    }
}

import Foundation
import KeelRESP

/// The sorted set editor (FR-ED05): one row per member, named by the member's bytes, whose value is its score as text
/// (`SortedSetEditor.scoreText`). Members load by score in pages of 500 (`ZRANGE … BYSCORE … LIMIT` where the server
/// has it, else `ZRANGEBYSCORE`), lowest first or, toggled, highest first. Changing a score (`ZADD XX`) and removing
/// (`ZREM`) are draft changes saved together in the shell's `WATCH` + `MULTI/EXEC`; adding (`ZADD`) and incrementing
/// (`ZINCRBY`) run at once. Pattern search pages through `ZSCAN … MATCH`.
public enum SortedSetEditor {
    /// Members per page, and `ZSCAN`'s COUNT.
    public static let pageSize = 500
    /// `ZSCAN` may answer a round with few or no matches; a search page stops after this many rounds so it stays quick.
    static let scanRounds = 8
    private static let startCursor = Data("0".utf8)

    public static let binding = EditorBinding(load: load, writes: writes, loadMore: loadMore, saveGuard: saveGuard, reread: reread, editsValues: false)

    // MARK: - Scores

    /// A score in full double precision: Swift's shortest text that reads back as the same double ("0.1",
    /// "0.30000000000000004", "1e+20"), whole numbers without a fraction ("42"), and `inf` / `-inf`.
    public static func scoreText(_ score: Double) -> String {
        if score.isInfinite { return score < 0 ? "-inf" : "inf" }
        let text = DataOperation.score(score)
        // Large whole numbers come back as "9007199254740992.0"; the fraction adds nothing.
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// The score a user typed: a number (`1.5`, `-3`, `1e3`) or `inf`, `+inf`, `-inf`; nil for anything else (NaN included).
    public static func parseScore(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), !value.isNaN else { return nil }
        return value
    }

    /// A row's score; nil only for bytes that are not a score (never for rows this editor made).
    public static func score(of row: EditorRow) -> Double? { parseScore(String(decoding: row.value, as: UTF8.self)) }

    public static func row(_ member: Data, score: Double) -> EditorRow { EditorRow(id: member, value: Data(scoreText(score).utf8)) }

    // MARK: - Paging

    /// Where the next page starts: the last score loaded and how many members with exactly that score are loaded (the
    /// next page skips them with `LIMIT`), in the page's direction. Encoded as the opaque "Load more" cursor.
    public struct Cursor: Sendable, Equatable {
        public var descending: Bool
        public var score: Double
        public var skip: Int

        public init(descending: Bool, score: Double, skip: Int) { self.descending = descending; self.score = score; self.skip = skip }

        /// "a 1.5 3" / "d -inf 1": direction, score, members at that score already loaded.
        public var data: Data { Data("\(descending ? "d" : "a") \(scoreText(score)) \(skip)".utf8) }

        public init?(_ data: Data) {
            let parts = String(decoding: data, as: UTF8.self).split(separator: " ")
            guard parts.count == 3, parts[0] == "a" || parts[0] == "d", let score = parseScore(String(parts[1])), let skip = Int(parts[2]), skip >= 0 else { return nil }
            self.init(descending: parts[0] == "d", score: score, skip: skip)
        }
    }

    /// The first page, lowest scores first (AC1); Reload comes here too.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        try await load(key: key, descending: false, service: service, context: context)
    }

    /// The first page, highest scores first with `descending`. A sorted set is never empty: no members means no key.
    public static func load(key: Data, descending: Bool, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let page = try await range(key, from: nil, descending: descending, service, context)
        guard !page.rows.isEmpty else { throw EditorReads.gone }
        // Guard reads depend on which scores change, so the save builds them (`saveGuard`); the key alone is watched here.
        return LoadedValue(rows: page.rows, watch: WatchGuard(key: key, reads: [], expected: []), next: page.next)
    }

    /// "Load more": the page after `cursor`, in the cursor's direction.
    @Sendable public static func loadMore(key: Data, cursor: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        guard let cursor = Cursor(cursor) else { throw .invalidRequest("The sorted set's page position is not valid.") }
        return try await range(key, from: cursor, descending: cursor.descending, service, context)
    }

    /// The paging command for this server (AC3): `ZRANGE … BYSCORE` where probed available (6.2+), else `ZRANGEBYSCORE`.
    public static func pageOperation(key: Data, from cursor: Cursor?, descending: Bool, byScore: Bool) -> DataOperation {
        // The next page starts at the last score loaded, inclusive, skipping the members with that score already loaded:
        // an exclusive bound would drop the rest of a score shared by many members.
        let start = cursor.map { Data(DataOperation.score($0.score).utf8) } ?? Data((descending ? "+inf" : "-inf").utf8)
        let end = Data((descending ? "-inf" : "+inf").utf8)
        return .sortedSetRange(
            key: key, min: descending ? end : start, max: descending ? start : end, offset: cursor?.skip ?? 0, count: pageSize, reverse: descending, byScore: byScore)
    }

    private static func range(_ key: Data, from cursor: Cursor?, descending: Bool, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError)
        -> EditorPage
    {
        let byScore = await service.supports(.zrangeByScore, context: context)
        let reply = try await EditorReads.read(pageOperation(key: key, from: cursor, descending: descending, byScore: byScore), service, context)
        guard let rows = scoredRows(reply) else { throw EditorReads.unexpected(reply, type: "sorted set") }
        return EditorPage(rows: rows, next: next(after: rows, from: cursor, descending: descending)?.data)
    }

    /// The cursor after a page: nil when the page came back short (nothing follows it).
    static func next(after rows: [EditorRow], from cursor: Cursor?, descending: Bool) -> Cursor? {
        guard rows.count >= pageSize, let last = rows.last.flatMap(score(of:)) else { return nil }
        // The members sharing the last score; the next page starts at that score and skips them.
        let ties = rows.reversed().prefix { score(of: $0) == last }.count
        // Still on the previous page's last score (the whole page tied): the members skipped then are still before it.
        let skipped = cursor.map { $0.score == last ? $0.skip : 0 } ?? 0
        return Cursor(descending: descending, score: last, skip: skipped + ties)
    }

    // MARK: - Saving

    /// One `ZADD XX` of the changed scores (it never adds a member someone else removed meanwhile), then one `ZREM` of the
    /// removed members. Members are only ever added at once (`add`), never in the draft.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] {
        let (changed, removed) = touched(loaded: loaded, draft: draft)
        var writes: [DataOperation] = []
        let scored = changed.compactMap { row in score(of: row).map { DataOperation.ScoredMember(score: $0, member: row.id) } }
        if !scored.isEmpty { writes.append(.sortedSetAdd(key: key, members: scored, existingOnly: true)) }
        if !removed.isEmpty { writes.append(.sortedSetRemove(key: key, members: removed)) }
        return writes
    }

    /// Each changed member's score must still be the one loaded (`ZSCORE`), so a change made elsewhere is a `CONFLICT`
    /// rather than overwritten. Removals carry no guard read: removing a member is right whatever its score became.
    @Sendable public static func saveGuard(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> WatchGuard {
        let before = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let guarded = touched(loaded: loaded, draft: draft).changed.compactMap { before[$0.id] }
        return WatchGuard(
            key: key, reads: guarded.map { .sortedSetScore(key: key, member: $0.id) },
            // RESP3's double; a RESP2 server's bulk string compares equal by value (`DataCommandService.sameScore`).
            expected: guarded.map { score(of: $0).map(RESPValue.double) ?? .null })
    }

    /// After a save: each changed or removed member is read back (`ZSCORE`); its row takes the server's score or leaves.
    /// The pages loaded stay, and the rows re-sort by their new scores (AC2).
    @Sendable public static func reread(key: Data, loaded: LoadedValue, draft: [EditorRow], service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> LoadedValue
    {
        let (changed, removed) = touched(loaded: loaded.rows, draft: draft)
        var value = loaded
        for member in changed.map(\.id) + removed {
            place(member, score: try await currentScore(member, key: key, service: service, context: context), in: &value)
        }
        return value
    }

    /// `member`'s score on the server (`ZSCORE`); nil when it is not a member.
    public static func currentScore(_ member: Data, key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> Double? {
        let reply = try await EditorReads.read(.sortedSetScore(key: key, member: member), service, context)
        // A null reply means the member is gone; anything else must be a score.
        if reply.isNull { return nil }
        guard let score = scoreValue(reply) else { throw EditorReads.unexpected(reply, type: "sorted set") }
        return score
    }

    /// Sets `member`'s score in `value` (nil removes it), keeping the "Load more" cursor right: a member that leaves the
    /// cursor's score no longer counts among the members the next page skips, so none is missed. A new member joins the
    /// rows (an add, a search result) even beyond the loaded pages; the next page that holds it again keeps one row.
    public static func place(_ member: Data, score: Double?, in value: inout LoadedValue) {
        let index = value.rows.firstIndex { $0.id == member }
        let old = index.flatMap { Self.score(of: value.rows[$0]) }
        if let index {
            if let score { value.rows[index] = row(member, score: score) } else { value.rows.remove(at: index) }
        } else if let score {
            value.rows.append(row(member, score: score))
        }
        // Only a member that was counted in the cursor's skip (it had the cursor's score) and now has another score (or
        // none) shifts the next page: one fewer member at that score precedes it.
        guard let data = value.next, var cursor = Cursor(data), let old, old == cursor.score, score != old, cursor.skip > 0 else { return }
        cursor.skip -= 1
        value.next = cursor.data
    }

    /// Rows whose score the draft changed (with the new score), and the members it removed, in loaded order.
    private static func touched(loaded: [EditorRow], draft: [EditorRow]) -> (changed: [EditorRow], removed: [Data]) {
        let after = Dictionary(draft.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        var changed: [EditorRow] = [], removed: [Data] = []
        for row in loaded {
            guard let value = after[row.id] else { removed.append(row.id); continue }
            if value != row.value { changed.append(EditorRow(id: row.id, value: value)) }
        }
        return (changed, removed)
    }

    // MARK: - Immediate actions

    /// "+ Add member": `ZADD` of one member, run at once. An existing member takes the new score.
    public static func add(_ member: Data, score: Double, key: Data) -> [DataOperation] {
        [.sortedSetAdd(key: key, members: [DataOperation.ScoredMember(score: score, member: member)])]
    }

    /// `ZADD`'s count from `EXEC`'s replies: 1 added, 0 already a member (its score was updated); nil for anything else.
    public static func added(_ reply: RESPValue) -> Bool? {
        guard case .array(let replies) = reply, case .integer(let count)? = replies.first else { return nil }
        return count > 0
    }

    public static let updatedExistingText = "Already a member; its score was updated."

    /// Increment…: `ZINCRBY`, run at once, so it adds to whatever the score is on the server.
    public static func increment(_ member: Data, by amount: Double, key: Data) -> [DataOperation] {
        [.sortedSetIncrement(key: key, increment: amount, member: member)]
    }

    /// The new score from `EXEC`'s replies for `increment`.
    public static func incremented(_ reply: RESPValue) -> Double? {
        guard case .array(let replies) = reply, let first = replies.first else { return nil }
        return scoreValue(first)
    }

    // MARK: - Search

    /// One page of `ZSCAN … MATCH pattern`: up to about `pageSize` matches or the end, in a bounded number of rounds.
    /// `cursor` nil starts the scan; the page's `next` is nil once it is complete.
    public static func search(key: Data, pattern: Data, cursor: Data?, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> EditorPage {
        var rows: [EditorRow] = [], seen = Set<Data>(), cursor = cursor ?? startCursor
        for _ in 0..<scanRounds {
            let reply = try await EditorReads.read(.sortedSetScan(key: key, cursor: cursor, match: pattern, count: pageSize), service, context)
            guard case .array(let parts) = reply, parts.count == 2, case .bulkString(let next) = parts[0], let page = scoredRows(parts[1]) else {
                throw EditorReads.unexpected(reply, type: "sorted set")
            }
            // `ZSCAN` may return a member twice within a scan; the page keeps it once.
            rows += page.filter { seen.insert($0.id).inserted }
            cursor = next
            if cursor == startCursor || rows.count >= pageSize { break }
        }
        return EditorPage(rows: rows, next: cursor == startCursor ? nil : cursor)
    }

    // MARK: - Replies

    /// Members with scores: a flat `member, score, …` array (RESP2, and `ZSCAN`'s page) or `[member, score]` pairs (RESP3).
    static func scoredRows(_ reply: RESPValue) -> [EditorRow]? {
        guard case .array(let items) = reply else { return nil }
        let pairs = items.compactMap { item -> [RESPValue]? in if case .array(let pair) = item, pair.count == 2 { pair } else { nil } }
        // RESP3's pairs flatten to RESP2's layout, so one loop reads both.
        let flat = !items.isEmpty && pairs.count == items.count ? pairs.flatMap { $0 } : items
        guard flat.count.isMultiple(of: 2) else { return nil }
        var rows: [EditorRow] = []
        rows.reserveCapacity(flat.count / 2)
        for index in stride(from: 0, to: flat.count, by: 2) {
            guard case .bulkString(let member) = flat[index], let score = scoreValue(flat[index + 1]) else { return nil }
            rows.append(row(member, score: score))
        }
        return rows
    }

    /// A score as RESP3 (a double) or RESP2 (a bulk string, `inf` / `-inf` included) sends it.
    static func scoreValue(_ reply: RESPValue) -> Double? {
        switch reply {
        case .double(let value): return value.isNaN ? nil : value
        case .bulkString(let text), .simpleString(let text): return parseScore(String(decoding: text, as: UTF8.self))
        default: return nil
        }
    }
}

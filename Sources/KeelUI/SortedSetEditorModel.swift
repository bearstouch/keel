import Combine
import Foundation
import KeelCore

/// The sorted set editor's table (FR-ED05) over an `EditorSession`: the draft's members sorted by score as loaded, so an
/// edited row keeps its place until the save re-reads it (AC2), lowest first or, toggled, highest first. Score changes
/// and removals are draft edits the save bar counts; adding and incrementing run at once (while nothing is unsaved).
/// A pattern search (`ZSCAN … MATCH`) shows its matches in place of the pages.
@MainActor
public final class SortedSetEditorModel: ObservableObject {
    /// The `ZSCAN` pattern typed in the search field; `search()` runs it.
    @Published public var pattern = ""
    /// The table: the draft's members, or the search's matches while a search is shown.
    @Published public private(set) var rows: [EditorRow] = []
    /// Highest scores first. A paged set reloads in the new direction; a fully loaded one re-sorts.
    @Published public private(set) var descending = false
    /// The last search's matches; nil while the pages are shown.
    @Published public private(set) var searchResults: [EditorRow]?
    /// Where "Search more" continues; nil once the scan is complete.
    @Published public private(set) var searchNext: Data?
    @Published public private(set) var isSearching = false
    /// What an action did when it wasn't the obvious ("Already a member; its score was updated.").
    @Published public private(set) var notice: String?
    /// A score that doesn't parse, or a failed search; the session's own failures are its `actionFailure`.
    @Published public private(set) var failure: String?

    public let session: EditorSession
    private var subscriptions: [AnyCancellable] = []
    /// The pattern the shown results belong to, so "Search more" continues the same scan.
    private var searchedPattern = Data()

    public init(session: EditorSession) {
        self.session = session
        subscriptions.append(session.$draft.sink { [weak self] in self?.refresh(draft: $0) })
        subscriptions.append(
            session.$loaded.sink { [weak self] value in
                guard let self else { return }
                // A save's read-back drops only the members the server no longer has (`ZSCORE`): they leave the shown
                // matches too, which would otherwise list a removed member as if it were still there.
                if self.session.phase == .saving, self.searchResults != nil, let before = self.session.loaded {
                    let kept = Set((value?.rows ?? []).map(\.id)), gone = Set(before.rows.map(\.id)).subtracting(kept)
                    if !gone.isEmpty { self.searchResults?.removeAll { gone.contains($0.id) } }
                }
                // A paged set shows the direction it was read in (Reload reads lowest first again).
                if let next = value?.next, let cursor = SortedSetEditor.Cursor(next) { self.descending = cursor.descending }
                self.refresh(loaded: value)
            })
    }

    /// "Showing 1–500 of 100,000" while more can be loaded; nil when every member is loaded.
    public var pageText: String? {
        guard searchResults == nil, session.hasMore, let loaded = session.loaded else { return nil }
        let count = KeyIndexFooter.grouped(loaded.rows.count)
        return session.header.length.map { "Showing 1–\(count) of \(KeyIndexFooter.grouped(Int(clamping: $0)))" } ?? "Showing 1–\(count)"
    }

    /// Add and Increment re-read the set, which would drop unsaved edits, so they wait for them to be saved or reverted.
    public var canRunAction: Bool { session.allowsWrites && session.canRunAction }
    /// Reversing a paged set reloads it, which would drop unsaved edits; a fully loaded one only re-sorts.
    public var canToggleOrder: Bool { !session.hasMore || session.canRunAction }

    // MARK: - Order

    public func toggleOrder() async {
        guard canToggleOrder else { return }
        let reversed = !descending
        guard session.hasMore else { descending = reversed; refresh(); return }
        // Only part of the set is loaded: the other end is a different page, read from the server.
        await session.loadWindow { key, service, context async throws(DataCommandError) in
            try await SortedSetEditor.load(key: key, descending: reversed, service: service, context: context)
        }
        if session.actionFailure == nil { descending = reversed; refresh() }
    }

    // MARK: - Draft edits

    /// Change Score…: the draft takes the new score; the save sends `ZADD XX`. Typing the loaded score again undoes it.
    @discardableResult
    public func changeScore(_ member: Data, to text: String) -> Bool {
        notice = nil; failure = nil
        guard session.allowsWrites else { return false }
        guard let score = SortedSetEditor.parseScore(text) else { failure = Self.invalidScore; return false }
        let updated = SortedSetEditor.row(member, score: score)
        includeSearchResult(member)
        session.update(session.draft.map { $0.id == member ? updated : $0 })
        return true
    }

    /// Remove: the member leaves the draft; the save sends `ZREM`.
    public func remove(_ member: Data) {
        guard session.allowsWrites else { return }
        notice = nil; failure = nil
        includeSearchResult(member)
        session.update(session.draft.filter { $0.id != member })
        if session.selectedRow == member { session.select(nil) }
    }

    /// Opens a row in the viewer; a search result joins the loaded value so the viewer (and edits) can find it.
    public func select(_ member: Data) {
        includeSearchResult(member)
        session.select(member)
    }

    /// A search result not in the draft yet joins the loaded value first, so the viewer finds it and a change to it
    /// counts and is guarded.
    private func includeSearchResult(_ member: Data) {
        guard !session.draft.contains(where: { $0.id == member }), let shown = searchResults?.first(where: { $0.id == member }) else { return }
        session.include(shown)
    }

    // MARK: - Immediate actions

    /// "+ Add member": `ZADD` at once. The member joins the table and opens in the viewer; an existing member takes the
    /// new score, and the notice says so.
    public func add(_ member: Data, score text: String) async {
        notice = nil; failure = nil
        guard canRunAction else { return }
        guard let score = SortedSetEditor.parseScore(text) else { failure = Self.invalidScore; return }
        // Nil: refused, failed or an unknown outcome; `session.actionFailure` says which.
        guard let reply = await session.run(SortedSetEditor.add(member, score: score, key: session.key), watch: nil), let added = SortedSetEditor.added(reply) else {
            await reconcile(member)
            return
        }
        if !added { notice = SortedSetEditor.updatedExistingText }
        settle(member, score: score)
    }

    /// Increment…: `ZINCRBY` at once; the row takes the score the server answered.
    public func increment(_ member: Data, by text: String) async {
        notice = nil; failure = nil
        guard canRunAction else { return }
        guard let amount = SortedSetEditor.parseScore(text) else { failure = Self.invalidScore; return }
        guard let reply = await session.run(SortedSetEditor.increment(member, by: amount, key: session.key), watch: nil),
            let score = SortedSetEditor.incremented(reply)
        else {
            await reconcile(member)
            return
        }
        settle(member, score: score)
    }

    /// After an add or increment without a known result (an unknown outcome, a server error), the session's read-back
    /// touched no row, so the member's score is read again (`ZSCORE`), never re-sent (NFR-RL03): the table shows what
    /// the server has, and a retried increment can't stack on a score the user never saw.
    private func reconcile(_ member: Data) async {
        guard session.loaded != nil else { return }
        let score: Double?
        do throws(DataCommandError) {
            score = try await SortedSetEditor.currentScore(member, key: session.key, service: session.service, context: session.context)
        } catch { return }
        settle(member, score: score, select: false)
    }

    /// The member's new score (nil: not a member) replaces its row (or adds it) and keeps the page cursor right.
    private func settle(_ member: Data, score: Double?, select: Bool = true) {
        guard var value = session.loaded else { return }
        SortedSetEditor.place(member, score: score, in: &value)
        session.replaceLoaded(value)
        if let index = searchResults?.firstIndex(where: { $0.id == member }) {
            if let score { searchResults?[index] = SortedSetEditor.row(member, score: score) } else { searchResults?.remove(at: index) }
        }
        if select, score != nil { session.select(member) }
        refresh()
    }

    // MARK: - Search

    /// Runs `ZSCAN … MATCH pattern` from the start; an empty pattern shows the pages again.
    public func search() async {
        failure = nil
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { clearSearch(); return }
        searchedPattern = Data(trimmed.utf8)
        await scan(from: nil)
    }

    /// "Search more": the next matches of the same scan.
    public func searchMore() async {
        guard let next = searchNext, !isSearching else { return }
        await scan(from: next)
    }

    public func clearSearch() {
        searchResults = nil; searchNext = nil; failure = nil
        refresh()
    }

    private func scan(from cursor: Data?) async {
        isSearching = true
        defer { isSearching = false }
        let pattern = searchedPattern
        do throws(DataCommandError) {
            let page = try await SortedSetEditor.search(key: session.key, pattern: pattern, cursor: cursor, service: session.service, context: session.context)
            // The user started another search meanwhile.
            guard pattern == searchedPattern else { return }
            // "Search more" appends to the shown matches, skipping any the scan returned again.
            let previous = cursor == nil ? [] : searchResults ?? []
            let known = Set(previous.map(\.id))
            searchResults = previous + page.rows.filter { !known.contains($0.id) }
            searchNext = page.next
            refresh()
        } catch {
            failure = EditorSession.message(error)
        }
    }

    // MARK: - Sorting

    static let invalidScore = "Enter a number, inf or -inf."

    private func refresh(draft: [EditorRow]? = nil, loaded: LoadedValue?? = nil) {
        let draft = draft ?? session.draft
        let loadedRows = (loaded ?? session.loaded)?.rows ?? []
        // The order follows the scores as loaded: an edited row moves once the save re-reads it (AC2).
        let sortScores = Dictionary(loadedRows.map { ($0.id, SortedSetEditor.score(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let shown: [EditorRow]
        if let searchResults {
            // Matches show the draft's score where the user edited them, and leave when removed in the draft.
            let current = Dictionary(draft.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            shown = searchResults.compactMap { result in
                guard sortScores.keys.contains(result.id) else { return result }
                return current[result.id]
            }
        } else {
            shown = draft
        }
        let keyed = shown.map { (row: $0, score: (sortScores[$0.id] ?? nil) ?? SortedSetEditor.score(of: $0) ?? 0) }
        let descending = descending
        rows = keyed.sorted { a, b in
            // Redis's order: by score, then by member bytes; descending reverses both.
            if a.score != b.score { return descending ? a.score > b.score : a.score < b.score }
            return descending ? b.row.id.lexicographicallyPrecedes(a.row.id) : a.row.id.lexicographicallyPrecedes(b.row.id)
        }.map(\.row)
    }
}

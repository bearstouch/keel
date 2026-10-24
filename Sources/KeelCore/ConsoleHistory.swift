import Foundation

/// A profile's console history (FR-CO04): in memory only, newest last, at most `limit` entries, each line once — running
/// a line again moves it to the end. Lines with credentials arrive already masked (`ConsoleMasking`), so no secret is
/// ever kept. Never persisted in v1.
public struct ConsoleHistory: Sendable, Equatable {
    public static let limit = 1_000

    /// Oldest first.
    public private(set) var entries: [String] = []

    public init() {}

    /// Adds `line` as the newest entry; a blank line is ignored and an earlier copy of it removed.
    public mutating func add(_ line: String) {
        guard !line.allSatisfy(\.isWhitespace) else { return }
        entries.removeAll { $0 == line }
        entries.append(line)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// ⌃R: the index of the newest entry older than `before` (all entries when nil) that contains `query`, ignoring
    /// case (command names are case-insensitive); nil when none does. An empty query matches every entry.
    public func search(_ query: String, before: Int? = nil) -> Int? {
        let end = min(before ?? entries.count, entries.count)
        guard end > 0 else { return nil }
        return entries[..<end].lastIndex { query.isEmpty || $0.range(of: query, options: .caseInsensitive) != nil }
    }
}

/// Walking the history with ↑ / ↓ from the line being typed. The typed line (the draft) comes back after the newest
/// entry, so ↑ then ↓ never loses it.
public struct ConsoleHistoryCursor: Sendable, Equatable {
    /// The entry shown; nil while the draft is.
    public private(set) var index: Int?
    private var draft = ""

    public init() {}

    /// ↑: the next older entry, or nil when there is none (the line stays as it is).
    public mutating func previous(in history: ConsoleHistory, current: String) -> String? {
        let target: Int
        if let index { target = index - 1 } else { draft = current; target = history.entries.count - 1 }
        guard history.entries.indices.contains(target) else { return nil }
        index = target
        return history.entries[target]
    }

    /// ↓: the next newer entry, then the draft; nil when already on the draft.
    public mutating func next(in history: ConsoleHistory) -> String? {
        guard let index else { return nil }
        let target = index + 1
        guard history.entries.indices.contains(target) else { self.index = nil; return draft }
        self.index = target
        return history.entries[target]
    }

    /// After a command runs or the line is edited: ↑ starts from the newest entry again.
    public mutating func reset() { index = nil; draft = "" }
}

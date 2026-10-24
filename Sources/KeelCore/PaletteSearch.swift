import Foundation

/// One row of the command palette (FR-AP03). The palette's owner keeps what running it does; search sees only text.
public struct PaletteItem: Sendable, Equatable, Identifiable {
    /// Section order breaks score ties: a connection named like an action comes first, since opening is the usual intent.
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        case connection, tab, recentKey, database, action, settings

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Read before the title by VoiceOver and shown at the row's right edge.
        public var label: String {
            switch self {
            case .connection: "Connection"
            case .tab: "Tab"
            case .recentKey: "Recent key"
            case .database: "Database"
            case .action: "Command"
            case .settings: "Settings"
            }
        }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Muted text after the title (a folder, a menu, a profile and database); searched too, worth less than the title.
    public let subtitle: String
    /// The command's current shortcut, shown at the right; never searched.
    public let shortcut: String?

    public init(id: String, kind: Kind, title: String, subtitle: String = "", shortcut: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.shortcut = shortcut
    }
}

/// Fuzzy matching and ranking for the palette. The query splits into words matched in any order ("prod pay" finds
/// "payments-prod"); every word must match the title or subtitle. A word scores most as the start of a word, then as
/// a substring, then as letters in order; matches in the title count more than in the subtitle. Case and diacritics are
/// ignored.
public enum PaletteSearch {
    /// Rows the palette lists at most; ranking never holds more.
    public static let limit = 50

    public static func rank(_ items: [PaletteItem], query: String, limit: Int = limit) -> [PaletteItem] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        // No query: the sources' own order (open tabs and recent keys first is the caller's choice), kinds kept together.
        guard !words.isEmpty else { return Array(items.enumerated().sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }.prefix(limit).map(\.element)) }
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        candidates: for (order, item) in items.enumerated() {
            let title = normalized(item.title), subtitle = normalized(item.subtitle)
            var total = 0
            for word in words {
                // The title's score doubles, so a word in the title beats the same match in the subtitle.
                guard let best = [score(word, in: title).map { $0 * 2 }, score(word, in: subtitle)].compactMap({ $0 }).max() else { continue candidates }
                total += best
            }
            // Among equal matches the shorter title is the closer one ("payments-prod" before "payments-prod-replica").
            scored.append((item, total * 1_000 - min(title.count, 999), order))
        }
        // Highest score first, then section order, then the sources' order.
        scored.sort { ($1.score, $0.item.kind, $0.order) < ($0.score, $1.item.kind, $1.order) }
        return scored.prefix(limit).map(\.item)
    }

    /// How well `word` matches `text` (both normalized), nil for no match.
    static func score(_ word: String, in text: String) -> Int? {
        guard !word.isEmpty, !text.isEmpty else { return nil }
        if text.hasPrefix(word) { return 120 }
        if let range = text.range(of: word) {
            // Foundation can match where `hasPrefix` (grapheme clusters) didn't, e.g. inside an emoji sequence.
            guard range.lowerBound > text.startIndex else { return 100 }
            // A word start (after a separator) is how people abbreviate names like "payments-prod".
            let before = text[text.index(before: range.lowerBound)]
            return before.isLetter || before.isNumber ? 60 : 100
        }
        // Letters in order ("pmt" in "payments"): fewer gaps rank higher, but always below any substring.
        var gaps = 0, position = text.startIndex, previous: String.Index?
        for character in word {
            guard let found = text[position...].firstIndex(of: character) else { return nil }
            if let previous, text.index(after: previous) != found { gaps += 1 }
            previous = found; position = text.index(after: found)
        }
        return max(40 - gaps * 5, 5)
    }

    static func normalized(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}

/// Keys opened in this run, newest first, for the palette (FR-AP03). Memory only by design (02 → Never persisted: key
/// names from browsing): deliberately not `Codable`, owned by the app model and gone when the app quits.
public struct RecentKeys: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let profileID: UUID
        public let database: Int
        /// The key's exact bytes, used to reopen it; display escaping happens at the edge.
        public let key: Data

        public init(profileID: UUID, database: Int, key: Data) { self.profileID = profileID; self.database = database; self.key = key }
    }

    /// Keys kept across all connections; the oldest falls off.
    public static let limit = 20
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Moves a reopened key to the front instead of listing it twice.
    public mutating func record(_ entry: Entry) {
        // Huge names are not worth keeping: the palette would only show their first characters.
        guard entry.key.count <= 1_024 else { return }
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// A deleted profile's keys go with it.
    public mutating func forget(profileID: UUID) { entries.removeAll { $0.profileID == profileID } }
}

import Foundation

/// What the console offers for the line being typed (FR-CO05): command names (and a container's subcommands) that
/// start with the word under the cursor, and the inline hint drawn after the cursor — the rest of the selected name,
/// then the argument syntax still to type, like redis-cli's hints. Names come from the session's catalog: the server's
/// `COMMAND DOCS` merged over the bundled one. Key-name completion is P1.
public struct ConsoleCompletion: Sendable, Equatable {
    /// Upper-case names (`HSCAN`, or `LIST` after `CLIENT `), sorted; empty when nothing completes here.
    public var candidates: [String]
    /// The word the candidates replace, as typed (`HSC`).
    public var word: String
    /// Where `word` starts in the line, in characters.
    public var wordStart: Int

    public init(candidates: [String] = [], word: String = "", wordStart: Int = 0) { self.candidates = candidates; self.word = word; self.wordStart = wordStart }

    /// Whether the list is worth showing: something other than exactly the word already typed.
    public var showsList: Bool { !candidates.isEmpty && !(candidates.count == 1 && candidates[0].caseInsensitiveCompare(word) == .orderedSame) }

    /// The line with `candidates[index]` in place of the word (Tab, ⌃Space).
    public func accept(_ index: Int, in line: String) -> String {
        guard candidates.indices.contains(index) else { return line }
        return String(line.prefix(wordStart)) + candidates[index]
    }
}

public enum ConsoleCompleter {
    /// The completion for `line` with the cursor at its end.
    public static func complete(_ line: String, catalog: CommandCatalog) -> ConsoleCompletion {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let open = line.last.map { !$0.isWhitespace } ?? false
        // The command name being typed.
        if words.count == 1, open {
            let word = words[0]
            return ConsoleCompletion(candidates: matches(word, in: catalog.commandNames), word: word, wordStart: line.count - word.count)
        }
        // A container's subcommand: `CLIENT ` or `CLIENT LI`.
        if let first = words.first, catalog.containers.contains(first.lowercased()), words.count == 1 || (words.count == 2 && open) {
            let word = words.count == 2 ? words[1] : ""
            return ConsoleCompletion(candidates: matches(word, in: catalog.subcommandNames(of: first)), word: word, wordStart: line.count - word.count)
        }
        return ConsoleCompletion(wordStart: line.count)
    }

    /// The inline hint after the cursor: the rest of the selected candidate and its arguments while a name is typed,
    /// otherwise the syntax of the arguments not typed yet. Empty when the command is unknown or has no docs.
    public static func hint(_ line: String, completion: ConsoleCompletion, selected: Int = 0, catalog: CommandCatalog) -> String {
        if completion.candidates.indices.contains(selected) {
            let candidate = completion.candidates[selected]
            // Only while the typed word really is a prefix of it; the rest is shown in the candidate's case.
            guard candidate.lowercased().hasPrefix(completion.word.lowercased()) else { return "" }
            let rest = String(candidate.dropFirst(completion.word.count))
            let completed = completion.accept(selected, in: line)
            let arguments = remainingSyntax(completed + " ", catalog: catalog)
            return rest + (arguments.isEmpty ? "" : " " + arguments)
        }
        let arguments = remainingSyntax(line, catalog: catalog)
        guard !arguments.isEmpty else { return "" }
        // Typed right after a word: the hint starts one space further on.
        return line.last?.isWhitespace == false ? " " + arguments : arguments
    }

    /// The argument syntax still to type after `line`'s command (and subcommand): required arguments already typed are
    /// dropped one by one; an optional or repeated one stops that, since what was typed for it can't be told.
    /// A word still being typed counts as typed.
    static func remainingSyntax(_ line: String, catalog: CommandCatalog) -> String {
        let words = line.split(whereSeparator: \.isWhitespace).map { Data($0.utf8) }
        guard !words.isEmpty, let command = catalog.resolve(words) else { return "" }
        let nameWords = command.isSubcommand ? 2 : 1
        var typed = max(words.count - nameWords, 0)
        var arguments = command.docs?.arguments ?? []
        while typed > 0, let first = arguments.first, !first.optional, !first.multiple {
            arguments.removeFirst(); typed -= 1
        }
        return arguments.map(\.syntax).joined(separator: " ")
    }

    private static func matches(_ word: String, in names: [String]) -> [String] {
        let prefix = word.lowercased()
        return names.filter { $0.hasPrefix(prefix) }.map { $0.uppercased() }
    }
}

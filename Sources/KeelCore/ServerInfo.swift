import Foundation
import KeelRESP

/// One `key:value` line of `INFO`, as the server sent it.
public struct InfoField: Sendable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// One `# Name` section of `INFO` with every field in the server's order, unknown ones included (FR-SI01).
public struct InfoSection: Sendable, Equatable, Identifiable {
    /// The header as sent ("Server", "Keyspace", Dragonfly's "Transaction"); empty for lines before any header.
    public var name: String
    public var fields: [InfoField]

    public init(name: String, fields: [InfoField] = []) { self.name = name; self.fields = fields }

    public var id: String { name }
    /// What Show all titles it: the header, or "Other" for lines that came before one.
    public var title: String { name.isEmpty ? "Other" : name }
}

/// A section as Show all lists it: what the server sent, or "unavailable" for an overview section it didn't send
/// (FR-SI05: an older server, Dragonfly, or `INFO` refused by an ACL).
public enum InfoSectionStatus: Sendable, Equatable, Identifiable {
    case available(InfoSection)
    case unavailable(name: String)

    public var id: String {
        switch self {
        case .available(let section): return section.name
        case .unavailable(let name): return name
        }
    }

    public var title: String {
        switch self {
        case .available(let section): return section.title
        case .unavailable(let name): return name
        }
    }
}

/// A parsed `INFO` reply (FR-SI01): sections in the server's order, every line kept. Nothing here is logged or saved.
public struct InfoReport: Sendable, Equatable {
    /// The sections FR-SI01 promises under Show all; any of them the server didn't send is shown "unavailable".
    public static let expectedSections = ["Server", "Memory", "Clients", "Keyspace", "Persistence", "Replication", "Stats", "CPU"]

    public var sections: [InfoSection]
    /// The reply's lines without the line ends, for the Raw view.
    public var lines: [String]
    private var index: [String: String]

    public init(text: String) {
        var sections: [InfoSection] = []
        var lines: [String] = []
        var index: [String: String] = [:]
        // The section lines go to; nil until the first header (or a header-less line opens the unnamed one).
        var current: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if line.hasPrefix("#") {
                let name = line.dropFirst().trimmingCharacters(in: .whitespaces)
                // A repeated header (two `INFO` replies joined) continues the section it names, so names stay unique.
                if let existing = sections.firstIndex(where: { $0.name == name }) {
                    current = existing
                } else {
                    sections.append(InfoSection(name: name)); current = sections.count - 1
                }
                continue
            }
            // A line without a colon is kept with an empty value: every line the server sent appears under Show all.
            let field: InfoField
            if let colon = line.firstIndex(of: ":") {
                field = InfoField(name: String(line[..<colon]), value: String(line[line.index(after: colon)...]))
            } else {
                field = InfoField(name: line, value: "")
            }
            let target: Int
            if let current { target = current } else { sections.append(InfoSection(name: "")); target = sections.count - 1; current = target }
            sections[target].fields.append(field)
            // The first value wins, as in `InfoFields.parse`.
            if index[field.name] == nil { index[field.name] = field.value }
        }
        self.sections = sections; self.lines = lines; self.index = index
    }

    /// The first value of `field` in any section; nil when the server didn't send it.
    public subscript(field: String) -> String? { index[field] }

    /// A section by name, ignoring case ("cpu" finds "CPU").
    public func section(_ name: String) -> InfoSection? { sections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Show all: the expected sections first, unavailable when missing, then every other section the server sent.
    public var sectionStatuses: [InfoSectionStatus] {
        let expected = Self.expectedSections.map { name in section(name).map(InfoSectionStatus.available) ?? .unavailable(name: name) }
        let others = sections.filter { section in !Self.expectedSections.contains { $0.caseInsensitiveCompare(section.name) == .orderedSame } }
        return expected + others.map(InfoSectionStatus.available)
    }

    /// The Raw view's lines containing `query`, ignoring case; every line for an empty query.
    public func rawLines(matching query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension InfoReport {
    /// A bare `INFO` through the data path (`.browser` origin, allowed on read-only profiles). A server error is
    /// `PERMISSION_DENIED` for `NOPERM` (an ACL without INFO: every section is unavailable) or `SERVER_ERROR`.
    public static func load(service: DataCommandService, context: DataContext) async -> Result<InfoReport, KeyIndexError> {
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await service.execute(.operation(.info(section: nil)), origin: .browser, context: context).reply
        } catch {
            return .failure(KeyIndexError(code: error.code, message: KeyIndex.describe(error, command: "INFO")))
        }
        switch reply {
        case .error(let text), .blobError(let text): return .failure(KeyIndex.serverError(text.prefix(512)))
        default:
            guard let text = InfoFields.text(of: reply) else { return .failure(KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's INFO reply wasn't text.")) }
            return .success(InfoReport(text: text))
        }
    }
}

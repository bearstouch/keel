import Combine
import Foundation
import KeelCore

/// The stream viewer's entry table (FR-ED06) over an `EditorSession`: the loaded entries by ID, newest first or, toggled,
/// oldest first. Entries are read-only (AC3); selecting one lists its fields, and a field's value opens in the viewer
/// below (read-only). "Add entry" runs `XADD` at once and shows the new entry at the top, selected (AC2).
@MainActor
public final class StreamEditorModel: ObservableObject {
    /// The table: the loaded entries in the chosen order.
    @Published public private(set) var rows: [EditorRow] = []
    /// Newest first (the default). A paged stream reloads from the other end; a fully loaded one re-sorts.
    @Published public private(set) var newestFirst = true
    /// The entry whose fields are listed; nil lists none.
    @Published public private(set) var selectedEntry: Data?
    /// The selected entry's field shown in the viewer.
    @Published public private(set) var selectedField: Int?
    /// Why the entry couldn't be added before anything was sent (no fields, an empty name or ID); the session's own
    /// failures are its `actionFailure`.
    @Published public private(set) var failure: String?

    public let session: EditorSession
    private var subscriptions: [AnyCancellable] = []

    public init(session: EditorSession) {
        self.session = session
        subscriptions.append(
            session.$loaded.sink { [weak self] value in
                guard let self else { return }
                // A paged stream shows the direction it was read in (Reload and an add read newest first again).
                if let next = value?.next, let cursor = StreamEditor.Cursor(next) { self.newestFirst = cursor.descending }
                self.refresh(value?.rows ?? [])
            })
    }

    /// "Showing 1–500 of 82,113" while more can be loaded; nil when every entry is loaded.
    public var pageText: String? {
        guard session.hasMore, let loaded = session.loaded else { return nil }
        let count = KeyIndexFooter.grouped(loaded.rows.count)
        return session.header.length.map { "Showing 1–\(count) of \(KeyIndexFooter.grouped(Int(clamping: $0)))" } ?? "Showing 1–\(count)"
    }

    /// Adding re-reads the newest page, so it waits while anything else runs.
    public var canAdd: Bool { session.allowsWrites && session.canRunAction }
    /// Reversing a paged stream reads the other end; a fully loaded one only re-sorts.
    public var canToggleOrder: Bool { !session.hasMore || session.canRunAction }

    /// The selected entry's fields, in the entry's order.
    public var selectedFields: [DataOperation.FieldValue] {
        guard let selectedEntry, let row = rows.first(where: { $0.id == selectedEntry }) else { return [] }
        return StreamEditor.fields(of: row) ?? []
    }

    // MARK: - Order

    public func toggleOrder() async {
        guard canToggleOrder else { return }
        let reversed = !newestFirst
        guard session.hasMore else { newestFirst = reversed; refresh(); return }
        // Only part of the stream is loaded: the other end is a different page, read from the server.
        await session.loadWindow { key, service, context async throws(DataCommandError) in
            try await StreamEditor.load(key: key, descending: reversed, service: service, context: context)
        }
        if session.actionFailure == nil { newestFirst = reversed; refresh() }
    }

    // MARK: - Selection

    /// Lists the entry's fields and opens the first one's value in the viewer; nil closes both.
    public func select(_ entry: Data?) {
        selectedEntry = entry; selectedField = nil
        if entry != nil, !selectedFields.isEmpty { selectField(0) }
    }

    /// Opens one field's value in the viewer, titled by the field's name.
    public func selectField(_ index: Int) {
        let fields = selectedFields
        guard fields.indices.contains(index) else { return }
        selectedField = index
        session.viewer.open(fields[index].value, title: KeyDisplay.name(fields[index].field))
    }

    // MARK: - Add entry

    /// "Add entry": `XADD` at once with `id` (`*` for the server's) and the field/value pairs. The read-back is the newest
    /// page, so the new entry shows at the top and opens selected (AC2). Returns whether the entry was added.
    @discardableResult
    public func add(id: Data, fields: [DataOperation.FieldValue]) async -> Bool {
        failure = nil
        guard canAdd else { return false }
        if let problem = Self.problem(id: id, fields: fields) { failure = problem; return false }
        // Nil: refused, failed (the server rejected the ID) or an unknown outcome; `session.actionFailure` says which.
        let reply = await session.run(StreamEditor.add(id: id, fields: fields, key: session.key), watch: nil)
        // A read-back shows the newest page from the top; a refusal or failed read-back keeps the page, in its own order.
        newestFirst = session.loaded?.next.flatMap(StreamEditor.Cursor.init)?.descending ?? true; refresh()
        guard let reply, let added = StreamEditor.addedID(reply) else { return false }
        select(added)
        return true
    }

    /// Why the add sheet's input can't be sent; nil when it can. The server checks the ID itself (greater than the last);
    /// only its first byte is checked here, so it can't be taken for an `XADD` option.
    public static func problem(id: Data, fields: [DataOperation.FieldValue]) -> String? {
        if id.isEmpty { return "Enter an entry ID, or use an automatic one." }
        // `XADD key MAXLEN 0 * …` would trim the stream: an ID that doesn't start with a digit would be read as an option.
        if id != StreamEditor.autoID, id.first.map({ !(0x30...0x39).contains($0) }) ?? true { return "An entry ID starts with a digit (1700000000000-0)." }
        if fields.isEmpty { return "Add at least one field." }
        if fields.contains(where: { $0.field.isEmpty }) { return "Every field needs a name." }
        return nil
    }

    // MARK: - Sorting

    private func refresh(_ loaded: [EditorRow]? = nil) {
        let entries = loaded ?? session.loaded?.rows ?? []
        let newestFirst = newestFirst
        rows = entries.sorted { newestFirst ? StreamEditor.precedes($1.id, $0.id) : StreamEditor.precedes($0.id, $1.id) }
        // A reload may have dropped the selected entry (trimmed, or another page now).
        if let selectedEntry, !rows.contains(where: { $0.id == selectedEntry }) { self.selectedEntry = nil; selectedField = nil }
    }
}

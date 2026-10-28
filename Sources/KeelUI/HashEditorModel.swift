import Combine
import Foundation
import KeelCore

/// The hash editor's table (FR-ED02) over an `EditorSession`: the draft's fields sorted by name and filtered locally,
/// and add, rename and delete as draft edits the save bar counts. Adding or renaming onto a field that exists asks
/// first; for a hash not fully loaded the server is asked (`HGET`) about fields the table doesn't have.
@MainActor
public final class HashEditorModel: ObservableObject {
    public enum SortOrder: Equatable { case ascending, descending }

    /// An add or rename waiting for the user's yes to overwrite `field`.
    public struct PendingOverwrite: Equatable, Identifiable {
        public enum Edit: Equatable {
            case add(value: Data)
            case rename(from: Data)
        }

        public var field: Data
        public var edit: Edit
        public var id: Data { field }
    }

    /// Loaded-field substring, case-insensitive, over the displayed name.
    @Published public var filter = "" { didSet { refresh() } }
    @Published public var order = SortOrder.ascending { didSet { refresh() } }
    /// The draft's fields as the table shows them.
    @Published public private(set) var rows: [EditorRow] = []
    @Published public var pendingOverwrite: PendingOverwrite?
    /// Why the last add or rename didn't happen (an empty name, the server check failed).
    @Published public private(set) var message: String?

    public let session: EditorSession
    private var draftChanges: AnyCancellable?
    /// The last sort: the draft's ids, filter and order it was taken for, and the draft positions in table order. Typing
    /// in the viewer changes a value, never an id, so each keystroke reuses the order instead of comparing every name.
    private var sorted: (ids: [Data], filter: String, order: SortOrder, positions: [Int])?
    /// Sorts taken (tests check that typing takes none).
    private(set) var sorts = 0

    public init(session: EditorSession) {
        self.session = session
        draftChanges = session.$draft.sink { [weak self] in self?.refresh($0) }
    }

    /// "Showing 1–500 of 82,113" while more can be loaded (03 → Value editors); nil when every field is loaded.
    public var pageText: String? {
        guard session.hasMore, let loaded = session.loaded else { return nil }
        let count = KeyIndexFooter.grouped(loaded.rows.count)
        return session.header.length.map { "Showing 1–\(count) of \(KeyIndexFooter.grouped(Int(clamping: $0)))" } ?? "Showing 1–\(count)"
    }

    // MARK: - Edits

    /// "+ Add field": the new field is added to the draft and opened in the viewer.
    public func add(field: Data, value: Data) async {
        guard await checkServer(for: field) else { return }
        apply(HashEditor.add(field: field, value: value, to: session.draft, overwrite: false), pending: .add(value: value), field: field)
    }

    public func rename(_ field: Data, to newField: Data) async {
        if newField != field { guard await checkServer(for: newField) else { return } }
        apply(HashEditor.rename(field, to: newField, in: session.draft, overwrite: false), pending: .rename(from: field), field: newField)
    }

    /// The user's yes: the edit runs over the existing field.
    public func confirmOverwrite() {
        guard let pending = pendingOverwrite else { return }
        pendingOverwrite = nil
        switch pending.edit {
        case .add(let value): apply(HashEditor.add(field: pending.field, value: value, to: session.draft, overwrite: true), pending: pending.edit, field: pending.field)
        case .rename(let from): apply(HashEditor.rename(from, to: pending.field, in: session.draft, overwrite: true), pending: pending.edit, field: pending.field)
        }
    }

    public func cancelOverwrite() { pendingOverwrite = nil }

    public func delete(_ field: Data) {
        guard session.allowsWrites else { return }
        session.update(HashEditor.delete(field, from: session.draft))
        if session.selectedRow == field { session.select(nil) }
    }

    public func toggleOrder() { order = order == .ascending ? .descending : .ascending }

    private func apply(_ edit: HashEditor.Edit, pending: PendingOverwrite.Edit, field: Data) {
        message = nil
        switch edit {
        case .applied(let rows):
            session.update(rows)
            // Refused by the session (read-only, saving): nothing changed, so nothing to select.
            if session.draft == rows { session.select(field) }
        case .confirmOverwrite(let existing): pendingOverwrite = PendingOverwrite(field: existing, edit: pending)
        case .refused(let reason): message = reason
        }
    }

    /// A paged hash may hold `field` beyond the loaded pages: the server's row joins the loaded value, so the draft
    /// edit asks before overwriting it and the save guards it. False when the check itself failed.
    private func checkServer(for field: Data) async -> Bool {
        message = nil
        guard session.allowsWrites else { return false }
        guard session.hasMore, !field.isEmpty, session.loaded?.rows.contains(where: { $0.id == field }) == false else { return true }
        do throws(DataCommandError) {
            if let row = try await HashEditor.serverField(key: session.key, field: field, service: session.service, context: session.context) {
                session.include(row)
            }
            return true
        } catch {
            message = EditorSession.message(error)
            return false
        }
    }

    // MARK: - Table

    private func refresh(_ draft: [EditorRow]? = nil) {
        let draft = draft ?? session.draft
        let ids = draft.map(\.id)
        if let sorted, sorted.ids == ids, sorted.filter == filter, sorted.order == order { rows = sorted.positions.map { draft[$0] }; return }
        let named = draft.indices.map { (position: $0, id: draft[$0].id, name: KeyDisplay.name(draft[$0].id)) }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? named : named.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        let ascending = order == .ascending
        let positions = shown.sorted { a, b in
            // Names that compare equal (escaped bytes aside) fall back to the bytes, so the order is stable.
            let result = a.name.localizedStandardCompare(b.name)
            if result == .orderedSame { return ascending ? a.id.lexicographicallyPrecedes(b.id) : b.id.lexicographicallyPrecedes(a.id) }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.position)
        sorted = (ids, filter, order, positions); sorts += 1
        rows = positions.map { draft[$0] }
    }
}

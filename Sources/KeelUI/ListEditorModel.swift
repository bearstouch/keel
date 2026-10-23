import Combine
import Foundation
import KeelCore

/// The list editor's table (FR-ED03) over an `EditorSession`: the draft's items in index order. Editing an item (in the
/// viewer) and deleting one are draft edits the save bar counts; push, pop and insert shift indexes, so they run at once
/// through `EditorSession.run` while nothing is unsaved. Pops ask first on production profiles.
@MainActor
public final class ListEditorModel: ObservableObject {
    /// A pop waiting for the user's yes (production profiles): true for the head.
    @Published public var pendingPop: Bool?
    /// Why the last jump, insert or pop didn't start (an index that isn't a number, an item no longer loaded).
    @Published public private(set) var message: String?

    public let session: EditorSession

    public init(session: EditorSession) { self.session = session }

    /// The draft's items, in index order (deleted ones are gone until the save).
    public var rows: [EditorRow] { session.draft }

    /// "Showing 501–1,000 of 82,113" while the loaded window isn't the whole list; nil when it is.
    public var pageText: String? {
        guard let loaded = session.loaded, let first = loaded.rows.first.flatMap({ ListEditor.index(of: $0.id) }),
            let last = loaded.rows.last.flatMap({ ListEditor.index(of: $0.id) }), session.hasMore || first > 0
        else { return nil }
        let range = "Showing \(KeyIndexFooter.grouped(first + 1))–\(KeyIndexFooter.grouped(last + 1))"
        return session.header.length.map { "\(range) of \(KeyIndexFooter.grouped(Int(clamping: $0)))" } ?? range
    }

    /// Actions wait for a saved draft: they re-read the list, which would drop unsaved edits.
    public var canAct: Bool { session.allowsWrites && session.canRunAction }

    // MARK: - Draft edits

    /// Delete by index: the item leaves the draft; the save removes it with a sentinel + `LREM 1`.
    public func delete(_ id: Data) {
        guard session.allowsWrites else { return }
        session.update(session.draft.filter { $0.id != id })
        if session.selectedRow == id { session.select(nil) }
    }

    // MARK: - Immediate actions

    public func push(_ value: Data, atHead: Bool) async {
        message = nil
        guard canAct else { return }
        await run(ListEditor.push(value, key: session.key, atHead: atHead))
    }

    /// Pop at the head or the tail: on production the user confirms first (`pendingPop`), elsewhere it runs at once.
    public func pop(atHead: Bool) async {
        message = nil
        guard canAct else { return }
        if ListEditor.popNeedsConfirmation(session.context.profile) { pendingPop = atHead; return }
        await runPop(atHead: atHead)
    }

    public func confirmPop() async {
        guard let atHead = pendingPop else { return }
        pendingPop = nil
        await runPop(atHead: atHead)
    }

    public func cancelPop() { pendingPop = nil }

    private func runPop(atHead: Bool) async {
        guard canAct, let loaded = session.loaded else { return }
        await run(ListEditor.pop(key: session.key, atHead: atHead, loaded: loaded))
    }

    /// Insert before or after the item `id` names.
    public func insert(_ value: Data, relativeTo id: Data, before: Bool) async {
        message = nil
        guard canAct, let loaded = session.loaded else { return }
        // The window may have moved (a jump or a re-read) since the menu opened on this row.
        guard let index = ListEditor.index(of: id), let action = ListEditor.insert(value, key: session.key, at: index, before: before, loaded: loaded.rows) else {
            message = "That item is no longer loaded."; return
        }
        await run(action)
    }

    private func run(_ action: ListEditor.Action) async { await session.run(action.writes, watch: action.watch) }

    /// "Jump to index": the page starting at the index typed (0-based).
    public func jump(to text: String) async {
        message = nil
        guard let index = Int(text.trimmingCharacters(in: .whitespaces)), index >= 0 else { message = "Enter an index of 0 or more."; return }
        guard session.canRunAction else { message = "Save or revert your changes first."; return }
        session.select(nil)
        await session.loadWindow { key, service, context async throws(DataCommandError) in
            try await ListEditor.load(key: key, from: index, service: service, context: context)
        }
    }
}

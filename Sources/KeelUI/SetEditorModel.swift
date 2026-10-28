import Combine
import Foundation
import KeelCore

/// The set editor's member list (FR-ED04) over an `EditorSession`: the draft's members sorted by name and filtered
/// locally. "+ Add member" runs `SADD` at once (while nothing is unsaved) and reports a member that was already there;
/// removing is a draft edit the save bar counts.
@MainActor
public final class SetEditorModel: ObservableObject {
    /// Loaded-member substring, case-insensitive, over the displayed name.
    @Published public var filter = "" { didSet { refresh() } }
    /// The draft's members as the list shows them.
    @Published public private(set) var rows: [EditorRow] = []
    /// What the last add did when it changed nothing ("Already a member of this set."); failures are the session's.
    @Published public private(set) var notice: String?

    public let session: EditorSession
    private var draftChanges: AnyCancellable?
    /// The last sort, as in `HashEditorModel`: reused while the draft's members and the filter are the same.
    private var sorted: (ids: [Data], filter: String, positions: [Int])?
    private(set) var sorts = 0

    public init(session: EditorSession) {
        self.session = session
        draftChanges = session.$draft.sink { [weak self] in self?.refresh($0) }
    }

    /// "Showing 1–500 of 82,113" while more can be loaded; nil when every member is loaded.
    public var pageText: String? {
        guard session.hasMore, let loaded = session.loaded else { return nil }
        let count = KeyIndexFooter.grouped(loaded.rows.count)
        return session.header.length.map { "Showing 1–\(count) of \(KeyIndexFooter.grouped(Int(clamping: $0)))" } ?? "Showing 1–\(count)"
    }

    /// Adding re-reads the set, which would drop unsaved removals, so it waits for them to be saved or reverted.
    public var canAdd: Bool { session.allowsWrites && session.canRunAction }

    /// "+ Add member": `SADD` at once. The member joins the list (also when it was there already but not loaded) and
    /// opens in the viewer; `SADD` returning 0 says it was already a member (AC1).
    public func add(_ member: Data) async {
        notice = nil
        guard canAdd else { return }
        // Nil: refused, failed or an unknown outcome; `session.actionFailure` says which.
        guard let reply = await session.run(SetEditor.add(member, key: session.key), watch: nil), let outcome = SetEditor.addOutcome(reply) else { return }
        if outcome == .alreadyMember { notice = SetEditor.alreadyMemberText }
        session.include(SetEditor.row(member))
        session.select(member)
    }

    /// Remove: the member leaves the draft; the save sends `SREM`.
    public func remove(_ member: Data) {
        guard session.allowsWrites else { return }
        notice = nil
        session.update(session.draft.filter { $0.id != member })
        if session.selectedRow == member { session.select(nil) }
    }

    private func refresh(_ draft: [EditorRow]? = nil) {
        let draft = draft ?? session.draft
        let ids = draft.map(\.id)
        if let sorted, sorted.ids == ids, sorted.filter == filter { rows = sorted.positions.map { draft[$0] }; return }
        let named = draft.indices.map { (position: $0, id: draft[$0].id, name: KeyDisplay.name(draft[$0].id)) }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? named : named.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        let positions = shown.sorted { a, b in
            // Names that compare equal (escaped bytes aside) fall back to the bytes, so the order is stable.
            let result = a.name.localizedStandardCompare(b.name)
            if result == .orderedSame { return a.id.lexicographicallyPrecedes(b.id) }
            return result == .orderedAscending
        }.map(\.position)
        sorted = (ids, filter, positions); sorts += 1
        rows = positions.map { draft[$0] }
    }
}

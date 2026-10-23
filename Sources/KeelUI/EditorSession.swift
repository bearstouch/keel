import Combine
import Foundation
import KeelCore
import KeelRESP

/// One open key in the editor shell (03 → Value editors, FR-ED13): the header, the loaded value and the user's draft,
/// the save bar's state, saving with `WATCH` + `MULTI/EXEC`, and Reload / Overwrite after a `CONFLICT`. A type's editor
/// (KEEL-029…034) supplies the `EditorBinding` and edits `draft`; without one the shell shows the header only.
@MainActor
public final class EditorSession: ObservableObject {
    public enum Phase: Equatable {
        case loading, ready, saving
        /// The key changed on the server since it was loaded; the shell offers Reload or Overwrite.
        case conflict
        /// The last load or save failed; the message says what happened. The draft is kept.
        case failed(String)
    }

    public let key: Data
    public let type: KeyType
    public let binding: EditorBinding?
    /// Read-only profiles show the value in view mode: no draft changes, no save, write actions disabled.
    public var isReadOnly: Bool { context.profile.readOnly }

    @Published public private(set) var phase = Phase.loading
    @Published public private(set) var header: KeyHeader
    /// The value as last read from the server; nil until loaded (and always without a binding).
    @Published public private(set) var loaded: LoadedValue?
    /// The rows as the user edited them; equals `loaded.rows` while nothing is unsaved.
    @Published public private(set) var draft: [EditorRow] = []
    /// Rows that differ from the loaded value (the accent dots); its count is the save bar's.
    @Published public private(set) var changedRows: Set<Data> = []
    @Published public private(set) var details: KeyDetails?
    /// Why the last "Load all" failed; the first page stays shown.
    @Published public private(set) var loadAllFailure: String?
    /// Why Save is refused while the viewer shows what it shows: invalid JSON in JSON view, Raw text that doesn't parse.
    @Published public private(set) var saveBlock: String?
    /// The value viewer (KEEL-028): a string's whole value; collection editors open their selected element in it.
    public let viewer: ValueViewerModel

    let service: DataCommandService
    let context: DataContext

    /// `viewerChoices` and `separator` place the key under its pattern (`user:*`), whose viewer choice the tab remembers.
    public init(
        key: Data, type: KeyType, binding: EditorBinding?, service: DataCommandService, context: DataContext,
        viewerChoices: ValueViewerChoices = ValueViewerChoices(), separator: NamespaceSeparator = .default
    ) {
        self.key = key; self.type = type; self.binding = binding; self.service = service; self.context = context
        header = KeyHeader(type: type, readOnly: context.profile.readOnly)
        viewer = ValueViewerModel(
            choices: viewerChoices, pattern: ValueViewerMemory.pattern(of: key, separator: separator), isEditable: !context.profile.readOnly)
        viewer.onChange = { [weak self] state in self?.viewerChanged(state) }
    }

    /// A string is one row, its whole value, shown and edited in the viewer.
    public var showsWholeValue: Bool { type == .string && binding != nil && loaded != nil }
    /// Only part of the value is loaded (a string over 1 MiB): shown, never edited, until "Load all" (FR-ED01).
    public var partial: PartialLoad? { loaded?.partial }
    /// "Load all" for a partial load the binding can read whole (not over 64 MiB) while nothing else runs.
    public var canLoadAll: Bool { partial?.canLoadAll == true && phase != .loading && phase != .saving }

    public var unsavedChangeCount: Int { changedRows.count }
    public var hasUnsavedChanges: Bool { !changedRows.isEmpty }
    /// The floating bar shows only while there is something to save (AC1), never on a read-only profile.
    public var showsSaveBar: Bool { !isReadOnly && hasUnsavedChanges }
    public var saveBarText: String { "\(unsavedChangeCount) unsaved change\(unsavedChangeCount == 1 ? "" : "s")" }
    /// Add and Save controls, and the ⋯ menu's write actions, only on writable profiles (AC3).
    public var allowsWrites: Bool { !isReadOnly }

    // MARK: - Loading

    /// Reads the header and the value. Reload after a conflict comes here too, and discards the draft.
    public func load() async {
        phase = .loading
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
        guard let binding else { phase = .ready; return }
        do throws(DataCommandError) {
            adopt(try await binding.load(key, service, context))
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// "Load all" after a partial load: the whole value replaces the first page and editing opens. A failure keeps the
    /// page on screen (still read-only) and says why beside the partial notice.
    public func loadAll() async {
        guard canLoadAll, let loadAll = binding?.loadAll else { return }
        phase = .loading; loadAllFailure = nil
        do throws(DataCommandError) {
            adopt(try await loadAll(key, service, context))
        } catch {
            phase = .ready; loadAllFailure = Self.message(error)
        }
        // The value may have changed since the first page, so its size and TTL in the header are re-read too.
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
    }

    // MARK: - Editing

    /// The type's editor hands over its rows after each change. Ignored on read-only profiles, before loading and for
    /// a partial load (saving a first page would truncate the value).
    public func update(_ rows: [EditorRow]) {
        guard !isReadOnly, let loaded, loaded.partial == nil, phase != .saving else { return }
        draft = rows
        changedRows = EditorChanges.changedRows(loaded: loaded.rows, draft: rows)
        syncViewer()
    }

    /// ⌘Z before saving: back to the loaded value.
    public func revert() {
        guard let loaded, phase != .saving else { return }
        draft = loaded.rows; changedRows = []
        if phase == .conflict { phase = .ready }
        syncViewer()
    }

    // MARK: - Saving

    /// ⌘S: applies the draft in one transaction guarded by the value as loaded. A key changed elsewhere stops the save
    /// with `CONFLICT` and writes nothing; the draft stays for Reload or Overwrite.
    public func save() async { await save(guarded: true) }

    /// Overwrite after a conflict: the same writes without the guard, still all or nothing.
    public func overwrite() async { await save(guarded: false) }

    /// Cancel on the conflict alert: the draft stays unsaved.
    public func dismissConflict() { if phase == .conflict { phase = .ready } }

    /// Reload after a conflict: the server's value replaces the draft.
    public func reload() async { await load() }

    private func save(guarded: Bool) async {
        // While the viewer prepares a large value its view's complaint isn't known yet (JSON view of invalid JSON).
        guard !isReadOnly, let binding, let loaded, loaded.partial == nil, phase != .saving, hasUnsavedChanges, saveBlock == nil, !(showsWholeValue && viewer.state == nil)
        else { return }
        let writes = binding.writes(key, loaded.rows, draft)
        guard !writes.isEmpty else { revert(); return }
        phase = .saving
        let result: DataCommandResult
        do throws(DataCommandError) {
            result = try await service.executeTransaction(writes, unchanged: guarded ? loaded.watch : nil, context: context)
        } catch {
            switch error {
            case .conflict:
                phase = .conflict
            case .command(.outcomeUnknown), .command(.timeout):
                // The writes may or may not have run: re-read what the server has, never re-send (NFR-RL03).
                await refreshLoaded()
                phase = .failed("The connection dropped during the save, so its outcome is unknown. The value was reloaded; review it before saving again.")
            default:
                phase = .failed(Self.message(error))
            }
            return
        }
        if let failure = Self.serverError(in: result.reply) {
            phase = .failed(failure)
            return
        }
        // Saved: the server's value (and the guard's snapshot) is what the next save compares with.
        do throws(DataCommandError) {
            adopt(try await reread(binding))
        } catch {
            self.loaded = LoadedValue(rows: draft, watch: loaded.watch); changedRows = []
            phase = .failed("Saved, but reading the value back failed: \(Self.message(error))")
        }
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
    }

    /// A save's read-back reads the whole value again: through `load` a saved string over 1 MiB would come back as a
    /// first page, read-only, and an unknown outcome would leave a whole draft beside a partial `loaded`.
    private func reread(_ binding: EditorBinding) async throws(DataCommandError) -> LoadedValue {
        // `if let`, not a nil comparison: comparing an optional typed-throws closure to nil fails on macOS 14.
        if let loadAll = binding.loadAll { return try await loadAll(key, service, context) }
        return try await binding.load(key, service, context)
    }

    /// The server's value replaces the draft: nothing is unsaved.
    private func adopt(_ value: LoadedValue) {
        loaded = value; draft = value.rows; changedRows = []; loadAllFailure = nil
        phase = .ready
        viewer.isEditable = !isReadOnly && value.partial == nil
        syncViewer()
    }

    // MARK: - Viewer

    /// The viewer shows the whole value's draft; a revert, reload or save puts the new one in front of it. Unchanged
    /// bytes leave it alone, so the user's own edits don't re-render under the cursor.
    private func syncViewer() {
        guard type == .string, let row = draft.first, row.value != viewer.state?.bytes else { return }
        viewer.open(row.value, title: "Value")
    }

    /// After every viewer change: its bytes become the draft (the save bar counts them), its complaint blocks Save.
    private func viewerChanged(_ state: ValueViewerState) {
        saveBlock = state.saveBlock
        guard type == .string, let row = draft.first, row.value != state.bytes else { return }
        update([EditorRow(id: row.id, value: state.bytes)])
        // Refused (typing while a save runs): the viewer shows the draft again, so what's on screen is what saves.
        if draft.first?.value != state.bytes { syncViewer() }
    }

    /// After an unknown outcome: the loaded value becomes the server's, the draft stays so the dots show what differs.
    private func refreshLoaded() async {
        guard let binding, let value = try? await reread(binding) else { return }
        loaded = value
        changedRows = EditorChanges.changedRows(loaded: value.rows, draft: draft)
    }

    // MARK: - Details

    /// ⋯ → Details: encoding and exact TTL; `memory` measures the size too (on request).
    public func loadDetails(memory: Bool = false) async {
        details = await KeyDetails.load(key: key, memory: memory, service: service, context: context)
    }

    // MARK: - Messages

    /// `EXEC`'s refusal (`-EXECABORT …`), a guard read's error, or the first write that failed inside the transaction.
    static func serverError(in reply: RESPValue) -> String? {
        switch reply {
        case .error(let text), .blobError(let text): return String(decoding: text.prefix(512), as: UTF8.self)
        case .array(let replies): return replies.lazy.compactMap(serverError(in:)).first
        default: return nil
        }
    }

    static func message(_ error: DataCommandError) -> String {
        switch error {
        case .refused(.readOnly(let message)), .refused(.blocked(let message)): return message
        case .refused: return "Keel's safety policy refused the change."
        case .invalidRequest(let message): return message
        case .connection(let failure): return failure.message
        case .command(let error): return "The connection failed (\(error.code))."
        case .conflict: return "The key changed since it was loaded."
        }
    }
}

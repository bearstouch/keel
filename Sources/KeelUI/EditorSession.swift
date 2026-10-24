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
    /// The collection row shown in the viewer (a hash field); nil shows none. A string always shows its one row.
    @Published public private(set) var selectedRow: Data?
    /// "Load more" of a paged collection is running; Save waits for it.
    @Published public private(set) var isLoadingMore = false
    /// Why the last "Load more" failed; the rows loaded so far stay.
    @Published public private(set) var loadMoreFailure: String?
    /// Why the last immediate action (a list push, pop or insert) or window load failed; the editor stays as re-read.
    @Published public private(set) var actionFailure: String?
    /// Why Save is refused while the viewer shows what it shows: invalid JSON in JSON view, Raw text that doesn't parse.
    @Published public private(set) var saveBlock: String?
    /// The value viewer (KEEL-028): a string's whole value; collection editors open their selected element in it.
    public let viewer: ValueViewerModel

    let service: DataCommandService
    let context: DataContext
    let separator: NamespaceSeparator
    /// The wall clock for expiry times; tests fix it.
    var now: @Sendable () -> Date = Date.init
    /// The row the viewer was last opened on, so selecting another row with the same bytes still re-opens it.
    private var viewedRowID: Data?
    /// Bumped by every value adopted (load, reload, save), so a "Load more" page read before it is dropped.
    private var adoptions = 0

    /// `viewerChoices` and `separator` place the key under its pattern (`user:*`), whose viewer choice the tab remembers.
    public init(
        key: Data, type: KeyType, binding: EditorBinding?, service: DataCommandService, context: DataContext,
        viewerChoices: ValueViewerChoices = ValueViewerChoices(), separator: NamespaceSeparator = .default
    ) {
        self.key = key; self.type = type; self.binding = binding; self.service = service; self.context = context; self.separator = separator
        header = KeyHeader(type: type, readOnly: context.profile.readOnly)
        viewer = ValueViewerModel(
            choices: viewerChoices, pattern: ValueViewerMemory.pattern(of: key, separator: separator), isEditable: !context.profile.readOnly && binding?.editsValues != false)
        viewer.onChange = { [weak self] state in self?.viewerChanged(state) }
    }

    /// A string is one row, its whole value, shown and edited in the viewer.
    public var showsWholeValue: Bool { type == .string && binding != nil && loaded != nil }
    /// Only part of the value is loaded (a string over 1 MiB): shown, never edited, until "Load all" (FR-ED01).
    public var partial: PartialLoad? { loaded?.partial }
    /// "Load all" for a partial load the binding can read whole (not over 64 MiB) while nothing else runs.
    public var canLoadAll: Bool { partial?.canLoadAll == true && phase != .loading && phase != .saving }
    /// A paged collection with more to read ("Showing 1–500 of 82,113 · Load more").
    /// Only a binding with `loadMore` sets `next`.
    public var hasMore: Bool { loaded?.next != nil }
    public var canLoadMore: Bool { hasMore && !isLoadingMore && phase != .loading && phase != .saving }

    public var unsavedChangeCount: Int { changedRows.count }
    public var hasUnsavedChanges: Bool { !changedRows.isEmpty }
    /// The floating bar shows only while there is something to save (AC1), never on a read-only profile.
    public var showsSaveBar: Bool { !isReadOnly && hasUnsavedChanges }
    public var saveBarText: String { "\(unsavedChangeCount) unsaved change\(unsavedChangeCount == 1 ? "" : "s")" }
    /// Add and Save controls, and the ⋯ menu's write actions, only on writable profiles (AC3).
    public var allowsWrites: Bool { !isReadOnly }
    /// Immediate actions and another window re-read the value, so they wait until nothing is unsaved and nothing else runs.
    public var canRunAction: Bool { loaded != nil && partial == nil && !hasUnsavedChanges && phase == .ready && !isLoadingMore }

    // MARK: - Loading

    /// Reads the header and the value. Reload after a conflict comes here too, and discards the draft.
    public func load() async {
        phase = .loading; actionFailure = nil
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

    /// "Load more": the next page joins the loaded rows (and the draft). A field already loaded keeps its row: `HSCAN`
    /// can return a field twice, and the user may have edited it. A failure keeps what is loaded and says why.
    public func loadMore() async {
        guard canLoadMore, let binding, let loadMore = binding.loadMore, let cursor = loaded?.next else { return }
        isLoadingMore = true; loadMoreFailure = nil
        defer { isLoadingMore = false }
        let adoption = adoptions
        do throws(DataCommandError) {
            let page = try await loadMore(key, cursor, service, context)
            // A Reload meanwhile started the pages over: this page and its cursor belong to the old scan.
            guard adoption == adoptions else { return }
            // Re-read the current value: a save may not run meanwhile, but an add's server check may have merged a row.
            guard var value = loaded else { return }
            merge(page.rows, into: &value)
            value.next = page.next
            loaded = value
        } catch {
            if adoption == adoptions { loadMoreFailure = Self.message(error) }
        }
    }

    /// A row the server has but the editor didn't load (a hash field found before overwriting it): it joins the loaded
    /// value, so the save guards it and the draft's change to it counts as one.
    public func include(_ row: EditorRow) {
        guard var value = loaded, !value.rows.contains(where: { $0.id == row.id }) else { return }
        merge([row], into: &value)
        loaded = value
    }

    /// Adds `rows` not loaded yet to `value` and, unless the draft already has them (added or edited by the user), to the draft.
    private func merge(_ rows: [EditorRow], into value: inout LoadedValue) {
        let known = Set(value.rows.map(\.id)), drafted = Set(draft.map(\.id))
        let fresh = rows.filter { !known.contains($0.id) }
        value.rows += fresh
        draft += fresh.filter { !drafted.contains($0.id) }
        changedRows = EditorChanges.changedRows(loaded: value.rows, draft: draft)
    }

    // MARK: - Editing

    /// Opens a collection row in the viewer; nil closes it.
    public func select(_ row: Data?) {
        selectedRow = row
        syncViewer()
    }

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

    /// Overwrite after a conflict: the same writes without the guard, still all or nothing. Not for positional rows: a
    /// list's index edits would land on whichever items moved there.
    public func overwrite() async {
        guard canOverwrite else { return }
        await save(guarded: false)
    }

    /// The conflict alert offers Overwrite only where a draft's rows still name the same items (not a list's indexes).
    public var canOverwrite: Bool { binding?.positional != true }

    /// Cancel on the conflict alert: the draft stays unsaved.
    public func dismissConflict() { if phase == .conflict { phase = .ready } }

    /// Reload after a conflict: the server's value replaces the draft.
    public func reload() async { await load() }

    private func save(guarded: Bool) async {
        // While the viewer prepares a large value its view's complaint isn't known yet (JSON view of invalid JSON).
        guard !isReadOnly, let binding, let loaded, loaded.partial == nil, phase != .saving, !isLoadingMore, hasUnsavedChanges, saveBlock == nil,
            !(viewedRow != nil && viewer.state == nil)
        else { return }
        let writes = binding.writes(key, loaded.rows, draft)
        guard !writes.isEmpty else { revert(); return }
        phase = .saving
        let watch = binding.saveGuard?(key, loaded.rows, draft) ?? loaded.watch
        let result: DataCommandResult
        do throws(DataCommandError) {
            result = try await service.executeTransaction(writes, unchanged: guarded ? watch : nil, context: context)
        } catch {
            switch error {
            case .conflict:
                phase = .conflict
            case .command(.outcomeUnknown), .command(.timeout):
                // The writes may or may not have run: re-read what the server has, never re-send (NFR-RL03).
                await refreshLoaded()
                phase = .failed(
                    binding.positional
                        ? "The connection dropped during the save, so its outcome is unknown. The value was reloaded in place of your changes; check whether they were applied."
                        : "The connection dropped during the save, so its outcome is unknown. The value was reloaded; review it before saving again.")
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
            adopt(try await reread(binding, loaded))
        } catch {
            self.loaded = LoadedValue(rows: draft, watch: loaded.watch, next: loaded.next); changedRows = []
            phase = .failed("Saved, but reading the value back failed: \(Self.message(error))")
        }
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
    }

    /// A save's read-back reads the whole value again: through `load` a saved string over 1 MiB would come back as a
    /// first page, read-only, and an unknown outcome would leave a whole draft beside a partial `loaded`. A paged
    /// collection re-reads only the rows the save touched, keeping the pages loaded.
    private func reread(_ binding: EditorBinding, _ loaded: LoadedValue) async throws(DataCommandError) -> LoadedValue {
        // `if let`, not a nil comparison: comparing an optional typed-throws closure to nil fails on macOS 14.
        if let reread = binding.reread { return try await reread(key, loaded, draft, service, context) }
        if let loadAll = binding.loadAll { return try await loadAll(key, service, context) }
        return try await binding.load(key, service, context)
    }

    /// The server's value replaces the draft: nothing is unsaved.
    private func adopt(_ value: LoadedValue) {
        loaded = value; draft = value.rows; changedRows = []; loadAllFailure = nil; loadMoreFailure = nil; adoptions += 1
        phase = .ready
        // A reload or save keeps the selected field open while it still exists.
        if let selectedRow, !value.rows.contains(where: { $0.id == selectedRow }) { self.selectedRow = nil }
        viewer.isEditable = !isReadOnly && value.partial == nil && binding?.editsValues != false
        syncViewer()
    }

    // MARK: - Immediate actions

    /// An edit that runs at once rather than through the draft (a list push, pop or insert, which shift every index after
    /// them): its writes in one transaction under `watch`, then the value is re-read. Returns `EXEC`'s replies, or nil when
    /// nothing ran or the outcome is unknown; `actionFailure` says why.
    @discardableResult
    public func run(_ writes: [DataOperation], watch: WatchGuard?) async -> RESPValue? {
        guard allowsWrites, canRunAction, let binding, let loaded, !writes.isEmpty else { return nil }
        phase = .saving; actionFailure = nil
        var reply: RESPValue?
        do throws(DataCommandError) {
            let result = try await service.executeTransaction(writes, unchanged: watch, context: context)
            if let failure = Self.serverError(in: result.reply) { actionFailure = failure } else { reply = result.reply }
        } catch {
            switch error {
            case .conflict:
                actionFailure = "The key changed since it was loaded, so nothing was changed. The value was reloaded; check it and try again."
            case .command(.outcomeUnknown), .command(.timeout):
                // Never re-sent (NFR-RL03): the re-read below shows what the server has.
                actionFailure = "The connection dropped, so the outcome is unknown. The value was reloaded; check it before trying again."
            default:
                // Refused or not connected: nothing was sent, so what is shown is still the server's value.
                actionFailure = Self.message(error); phase = .ready
                return nil
            }
        }
        do throws(DataCommandError) {
            adopt(try await reread(binding, loaded))
        } catch {
            phase = .ready
            actionFailure = actionFailure ?? "Reading the value back failed: \(Self.message(error))"
        }
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
        return reply
    }

    /// An immediate action's known result (a sorted set member's new score) replaces the loaded value, without another read.
    public func replaceLoaded(_ value: LoadedValue) {
        guard canRunAction else { return }
        adopt(value)
    }

    /// Another window of the value replaces the loaded one (a list's "Jump to index"); a failure keeps the current one.
    public func loadWindow(_ read: (Data, DataCommandService, DataContext) async throws(DataCommandError) -> LoadedValue) async {
        guard canRunAction else { return }
        phase = .loading; actionFailure = nil
        do throws(DataCommandError) {
            adopt(try await read(key, service, context))
        } catch {
            phase = .ready; actionFailure = Self.message(error)
        }
    }

    // MARK: - Viewer

    /// The viewer shows the whole value's draft; a revert, reload or save puts the new one in front of it. Unchanged
    /// bytes leave it alone, so the user's own edits don't re-render under the cursor.
    private func syncViewer() {
        guard let row = viewedRow else {
            // The selected row went away (deleted, renamed, reverted): nothing to show or to block Save.
            if type != .string { viewedRowID = nil; saveBlock = nil }
            return
        }
        let bytes = shownBytes(row)
        guard row.id != viewedRowID || bytes != viewer.state?.bytes else { return }
        viewedRowID = row.id
        viewer.open(bytes, title: type == .string ? "Value" : KeyDisplay.name(row.id))
    }

    /// What the viewer shows of a row: its value, or its name where values aren't edited there (a sorted set's row value
    /// is the score, shown in the table; the member's bytes are what the viewer is for).
    private func shownBytes(_ row: EditorRow) -> Data { binding?.editsValues == false ? row.id : row.value }

    /// The draft row the viewer shows: a string's one row, or the selected collection row.
    var viewedRow: EditorRow? {
        if type == .string { return draft.first }
        guard let selectedRow else { return nil }
        return draft.first { $0.id == selectedRow }
    }

    /// After every viewer change: its bytes become the draft (the save bar counts them), its complaint blocks Save.
    private func viewerChanged(_ state: ValueViewerState) {
        // A read-only viewer (a set member) saves nothing from its view, so invalid JSON shown there can't block the draft.
        saveBlock = binding?.editsValues == false ? nil : state.saveBlock
        guard binding?.editsValues != false, let row = viewedRow, row.id == viewedRowID, row.value != state.bytes else { return }
        update(draft.map { $0.id == row.id ? EditorRow(id: row.id, value: state.bytes) : $0 })
        // Refused (typing while a save runs): the viewer shows the draft again, so what's on screen is what saves.
        if viewedRow?.value != state.bytes { syncViewer() }
    }

    /// After an unknown outcome: the loaded value becomes the server's, the draft stays so the dots show what differs.
    /// Positional rows can't keep the draft: after a delete that ran, its indexes name other items, and saving it again
    /// would overwrite or delete them.
    private func refreshLoaded() async {
        guard let binding, let current = loaded, let value = try? await reread(binding, current) else { return }
        if binding.positional { adopt(value); return }
        loaded = value
        changedRows = EditorChanges.changedRows(loaded: value.rows, draft: draft)
    }

    // MARK: - Details

    /// ⋯ → Details: encoding and exact TTL, and a stream's `XINFO STREAM` summary; `memory` measures the size too (on request).
    public func loadDetails(memory: Bool = false) async {
        details = await KeyDetails.load(key: key, memory: memory, stream: type == .stream, service: service, context: context)
    }

    // MARK: - Key actions (FR-ED10–FR-ED12, FR-ED15)

    /// What a key action did to the key itself; the browser follows it in the list.
    public enum KeyChange: Equatable {
        /// `replaced`: an existing key was overwritten, so the database holds one key fewer.
        case renamed(to: Data, replaced: Bool)
        case deleted
    }

    public enum RenameResult: Equatable {
        case renamed
        /// The new name is taken and nothing changed; renaming again with this token replaces that key.
        case needsOverwrite(KeyActions.RenameOverwrite)
        case failed(String)
    }

    /// A sheet the ⋯ menu or a shortcut (⌘E, ⌥⌘E) asked for; the shell presents it and clears this on dismiss.
    public enum KeyActionRequest: String, Identifiable {
        case rename, setTTL
        public var id: String { rawValue }
    }

    @Published public var requestedKeyAction: KeyActionRequest?
    /// Key → Delete Selected Keys… (⌘⌫) with one key open: the shell shows its normal delete confirmation (FR-ED12).
    @Published public var requestsDelete = false

    /// Set by the browser: a rename re-selects the key under its new name, a delete clears the editor.
    public var onKeyChange: ((KeyChange) -> Void)?
    /// When the key expires, as last read (the Set TTL sheet reads it on open); nil until then.
    @Published public private(set) var expiry: KeyExpiry?

    /// Rename, Set TTL and Delete: writable profiles, while nothing else runs (a module type without an editor too, FR-ED07).
    public var canRunKeyAction: Bool { allowsWrites && phase != .loading && phase != .saving && !isLoadingMore }
    /// A rename reopens the key under its new name, which would drop unsaved changes, so they are saved or reverted first.
    public var canRename: Bool { canRunKeyAction && !hasUnsavedChanges }

    /// Rename…: `RENAMENX`, or `RENAME` with the token from an earlier `needsOverwrite` (the user confirmed).
    public func rename(to newKey: Data, overwrite: KeyActions.RenameOverwrite? = nil) async -> RenameResult {
        guard canRename else { return .failed("Save or revert your changes before renaming.") }
        let outcome: KeyActions.RenameOutcome
        do throws(DataCommandError) {
            outcome = try await keyAction { [key, service, context] () async throws(DataCommandError) in
                try await KeyActions.rename(key, to: newKey, overwrite: overwrite, service: service, context: context)
            }
        } catch {
            return .failed(Self.keyActionMessage(error))
        }
        switch outcome {
        case .targetExists(let token): return .needsOverwrite(token)
        case .renamed:
            onKeyChange?(.renamed(to: newKey, replaced: overwrite != nil))
            return .renamed
        }
    }

    /// Set TTL…: applies the change, then shows the new expiry (clock time, or "—" after Persist) and re-reads the header.
    /// Returns why it failed; nil when applied.
    public func setTTL(_ change: KeyActions.TTLChange) async -> String? {
        guard canRunKeyAction else { return "Wait for the current action to finish." }
        var failure: String?
        do throws(DataCommandError) {
            expiry = try await keyAction { [key, service, context, now] () async throws(DataCommandError) in
                try await KeyActions.setTTL(key, change, service: service, context: context, now: now)
            }
        } catch {
            // The sheet shows what the server has now, whatever happened.
            await loadExpiry()
            failure = Self.keyActionMessage(error)
        }
        header = await KeyHeader.load(key: key, type: type, service: service, context: context)
        return failure
    }

    public func loadExpiry() async { expiry = await KeyActions.expiry(of: key, service: service, context: context, now: now) }

    /// Delete… after the normal confirmation: `UNLINK`, then the browser drops the key and the editor closes.
    /// Returns why it failed; nil when deleted.
    public func delete() async -> String? {
        guard canRunKeyAction else { return "Wait for the current action to finish." }
        do throws(DataCommandError) {
            try await keyAction { [key, service, context] () async throws(DataCommandError) in try await KeyActions.delete(key, service: service, context: context) }
        } catch {
            return Self.keyActionMessage(error)
        }
        onKeyChange?(.deleted)
        return nil
    }

    /// Runs one key action with the editor marked busy (no save or second action meanwhile), then restores its phase.
    private func keyAction<T>(_ body: () async throws(DataCommandError) -> T) async throws(DataCommandError) -> T {
        let previous = phase
        phase = .saving
        defer { if phase == .saving { phase = previous } }
        return try await body()
    }

    /// An unknown outcome the re-read couldn't settle: say so rather than "failed", since it may have happened.
    static func keyActionMessage(_ error: DataCommandError) -> String {
        switch error {
        case .command(.outcomeUnknown), .command(.timeout):
            return "The connection dropped, so the outcome is unknown. Refresh the list to see whether it was applied."
        default: return message(error)
        }
    }

    /// Why Export and Copy Value are unavailable; nil when they can run. They use the value as loaded from the server
    /// (unsaved changes aren't in it), and only a whole value: a first page exported as the file would silently drop the rest.
    public var exportBlock: String? {
        guard binding != nil else { return "There's no editor for this type, so there's no value to export." }
        guard let loaded else { return "The value isn't loaded." }
        if loaded.partial != nil { return "Only part of the value is loaded. Load all first." }
        if type != .string, loaded.next != nil || header.length != Int64(loaded.rows.count) {
            return "Only part of the value is loaded. Load every page first."
        }
        return nil
    }

    /// The export file's bytes: a string's raw value, a collection's JSON.
    public func exportData() -> Data? {
        guard exportBlock == nil, let loaded else { return nil }
        return ValueExport.data(key: key, type: type, rows: loaded.rows)
    }

    public var exportFileName: String { ValueExport.suggestedFileName(key: key, type: type, rows: loaded?.rows ?? [], separator: separator) }

    public func copyValueText() -> String? {
        guard exportBlock == nil, let loaded else { return nil }
        return ValueExport.copyText(key: key, type: type, rows: loaded.rows)
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

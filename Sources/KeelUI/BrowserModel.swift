import AppKit
import Combine
import KeelCore
import SwiftUI

/// One tab's browser state around the key list (FR-KB08, FR-KB09, FR-KB12): the database it shows and the switcher's
/// counts, Refresh, the `DBSIZE` total and the "Key no longer exists" notice. The tab (KEEL-026) owns it, puts
/// `DatabasePicker` in its toolbar and `BrowserPane` in its content.
@MainActor
public final class BrowserModel: ObservableObject {
    /// The databases the picker offers, with key counts from `INFO keyspace`.
    @Published public private(set) var databases: DatabaseList
    /// The database the list shows; the tab follows it.
    @Published public private(set) var database: Int
    /// The selected key when opening it found it gone (FR-KB12); the pane offers to remove it from the list.
    @Published public private(set) var missingKey: Data?
    /// The selected key, open in the editor shell (KEEL-027) once its presence check named its type.
    @Published public private(set) var editor: EditorSession?
    /// ⇧⌘N asked for the new-key sheet (FR-ED14).
    @Published public var showsNewKey = false
    /// The profile's read-only flag, read at `start()`; true until then, so New Key is never offered before it is known.
    @Published public private(set) var isReadOnly = true
    /// The typed confirmation for deleting the multi-key selection (FR-SF03, FR-SF04); the pane shows it as a sheet.
    @Published public var deleteConfirmation: TypedConfirmationModel?

    public let list: KeyListDataSource
    public let filter: KeyFilterModel?
    /// Cluster mode offers db0 only (FR-KB08).
    public let serverMode: ServerMode
    /// The server's `databases` (`DatabaseList.probeCount` at session setup); nil offers db0–db15.
    public let databaseCount: Int?
    /// Loads the first page after a restart; the tab resumes Auto-page here when that is the mode.
    let startScan: @MainActor (KeyIndex) async -> Void
    /// The type's editor; nil shows the shell without a value editor (types whose editor isn't built yet).
    let editorBinding: @MainActor (KeyType) -> EditorBinding?

    /// The viewer choice per key pattern, for every key this tab opens (03 → Value editors).
    let viewerChoices = ValueViewerChoices()

    /// Bumped by every refresh and switch, so counts that land for an earlier one are dropped.
    private var countsRequest = 0
    /// Bumped by every selection, so only the newest presence check reports.
    private var presenceRequest = 0
    private var selection: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    public init(
        list: KeyListDataSource, filter: KeyFilterModel? = nil, database: Int, serverMode: ServerMode = .standalone, databaseCount: Int? = nil,
        startScan: @escaping @MainActor (KeyIndex) async -> Void = { _ = await $0.loadMore() },
        editorBinding: @escaping @MainActor (KeyType) -> EditorBinding? = { _ in nil }
    ) {
        self.list = list; self.filter = filter; self.database = database; self.serverMode = serverMode; self.databaseCount = databaseCount
        self.startScan = startScan; self.editorBinding = editorBinding
        databases = DatabaseList(keyspace: [:], databaseCount: databaseCount, mode: serverMode)
        // Opening a key checks it still exists. The publisher fires before the property changes, hence the value.
        selection = list.$selectedKey.removeDuplicates().sink { [weak self] key in
            guard let self else { return }
            // Numbered here, not in the task, so a check that starts late can't outrank a newer selection's.
            self.presenceRequest += 1
            let request = self.presenceRequest
            Task { await self.checkSelection(key, request: request) }
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: KeyListCommands.refreshNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, self.isShown(in: window) else { return }
                    Task { await self.refresh() }
                }
            })
        observers.append(
            center.addObserver(forName: KeyListCommands.newKeyNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, self.isShown(in: window), self.canCreateKey else { return }
                    self.showsNewKey = true
                }
            })
        observers.append(
            center.addObserver(forName: KeyListCommands.selectDatabaseNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow, database = note.userInfo?[KeyListCommands.databaseKey] as? Int
                MainActor.assumeIsolated {
                    guard let self, let database, self.isShown(in: window) else { return }
                    Task { await self.selectDatabase(database) }
                }
            })
        let commands: [(Notification.Name, EditorCommand)] = [
            (EditorCommands.saveNotification, .save), (EditorCommands.revertNotification, .revert), (EditorCommands.renameNotification, .rename),
            (EditorCommands.setTTLNotification, .setTTL)
        ]
        for (name, action) in commands {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self, self.isShown(in: window), let editor = self.editor else { return }
                        switch action {
                        case .save: Task { await editor.save() }
                        case .revert: editor.revert()
                        case .rename: if editor.canRename { editor.requestedKeyAction = .rename }
                        case .setTTL: if editor.canRunKeyAction { editor.requestedKeyAction = .setTTL }
                        }
                    }
                })
        }
    }

    private enum EditorCommand { case save, revert, rename, setTTL }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Menu commands go to the key window's browser only.
    private func isShown(in window: NSWindow?) -> Bool { window != nil && list.scrollView.window === window }

    /// The first scan of a new tab, with the counts.
    public func start() async {
        isReadOnly = await list.index.context.profile.readOnly
        // Read-only profiles don't offer the delete (FR-KB11): no ⌫, no Delete N Keys… in the menu.
        list.onDelete = isReadOnly ? nil : { [weak self] in Task { await self?.requestDeleteSelection() } }
        await scan()
    }

    // MARK: - Refresh (⌘R)

    /// Restarts the scan keeping the filters and, once its key loads again, the selected key (FR-KB09); then
    /// re-reads `DBSIZE` and the switcher's counts. A key deleted meanwhile simply doesn't come back.
    public func refresh() async {
        let selected = await list.selectedKeyName()
        missingKey = nil
        await list.index.restart()
        if let selected { await list.select(keyBytes: selected) }
        await scan()
    }

    // MARK: - Database switcher

    /// ⌥⌘0…⌥⌘9 and the picker: shows `database` in the same tab with an empty list (FR-KB08). The filters and the
    /// paging mode stay; the selection doesn't (it named a key in another database). Databases the switcher doesn't
    /// offer (db1 on a cluster, db12 of 8) are ignored.
    public func selectDatabase(_ database: Int) async {
        guard database != self.database, databases.entry(database) != nil else { return }
        self.database = database
        missingKey = nil
        await list.select(keyBytes: nil)
        await list.index.switchDatabase(database)
        // The old database's total must not show beside the new one's keys.
        list.setTotalKeys(nil)
        await scan()
    }

    /// Reloads the list, loads the first page and fetches the counts alongside it.
    private func scan() async {
        // Numbered before the first await, so counts still landing for the previous database are dropped.
        countsRequest += 1
        let request = countsRequest
        await list.reload()
        async let counts: Void = loadCounts(request)
        await startScan(list.index)
        await list.reload()
        await counts
    }

    /// `DBSIZE` for the footer and `INFO keyspace` for the picker. A failure leaves the total unknown (the footer
    /// shows the loaded count only) and keeps the counts the picker had.
    private func loadCounts(_ request: Int) async {
        let index = list.index
        let size = await index.databaseSize()
        let counts = await DatabaseList.load(service: index.service, context: await index.context, databaseCount: databaseCount, mode: serverMode)
        guard request == countsRequest else { return }
        list.setTotalKeys(try? size.get())
        if case .success(let databases) = counts { self.databases = databases }
    }

    // MARK: - Missing keys (FR-KB12)

    private func checkSelection(_ key: Int?, request: Int) async {
        guard request == presenceRequest else { return }
        missingKey = nil
        // The selection's pinned bytes when known: after a removal, row numbers can name a neighbour until the reload.
        guard let key, list.selectedKey == key, let bytes = await list.selectedKeyName() else {
            if request == presenceRequest { editor = nil }
            return
        }
        let presence = await list.index.presence(of: bytes)
        // Only the newest selection reports, and only while that key is still the one selected.
        guard request == presenceRequest, list.selectedKey == key else { return }
        if presence == .missing { missingKey = bytes; editor = nil }
        if case .exists(let type) = presence { await open(bytes, type: type, request: request) }
        // The row now reads "expired" (or shows its new type); redraw it.
        await list.refreshRows(ofKeys: [key])
    }

    /// Opens `key` in the editor unless it already is (a refresh re-selects it; the open editor keeps its draft).
    private func open(_ key: Data, type: KeyType, request: Int) async {
        let index = list.index
        let context = await index.context
        // The same name in another database (after a switch) is another key.
        if let editor, editor.key == key, editor.type == type, editor.context.database == context.database { return }
        let editor = EditorSession(
            key: key, type: type, binding: editorBinding(type), service: await index.service, context: context,
            viewerChoices: viewerChoices, separator: await index.separator)
        // A newer selection while the context was read owns the editor now.
        guard request == presenceRequest else { return }
        editor.onKeyChange = { [weak self, weak editor] change in
            guard let self, let editor else { return }
            Task { await self.keyChanged(change, in: editor) }
        }
        self.editor = editor
        await editor.load()
    }

    // MARK: - Key actions (FR-ED10, FR-ED12)

    /// Follows the editor's rename or delete in the loaded keys without a rescan: a deleted key leaves the list and the
    /// editor shows the empty state; a renamed one is selected under its new name (reopening the editor there), unless
    /// the filter wouldn't list that name.
    func keyChanged(_ change: EditorSession.KeyChange, in session: EditorSession) async {
        guard editor === session else { return }
        let index = list.index
        editor = nil
        await list.select(keyBytes: nil)
        await index.remove(key: session.key)
        // The database holds one key fewer after a delete, or after a rename that replaced an existing key.
        let removesKey: Bool
        var added: Data?
        switch change {
        case .deleted: removesKey = true
        case .renamed(let newKey, let replaced):
            removesKey = replaced
            if await index.add(key: newKey, type: session.type) { added = newKey }
        }
        if removesKey { list.setTotalKeys(list.totalKeys.map { max($0 - 1, 0) }) }
        await list.reload()
        if let added { await list.select(keyBytes: added) }
    }

    // MARK: - Multi-key delete (FR-KB11, FR-SF04)

    /// ⌫ or Delete N Keys… on a selection of several keys: the typed confirmation listing them. Read-only profiles
    /// never ask (the policy would refuse every batch).
    public func requestDeleteSelection() async {
        // Counted twice: the rows before the await, the names after it (rows past the loaded range are skipped).
        let rows = list.selectedKeys
        guard !isReadOnly, rows.count > 1, let keys = await list.selectedKeyNames(), keys.count > 1 else { return }
        let index = list.index
        let context = await index.context
        // The user changed the selection while the names were read: only what is shown selected is offered.
        guard list.selectedKeys == rows, deleteConfirmation == nil else { return }
        let request = MultiKeyDelete.request(for: keys, profile: context.profile, database: context.database)
        deleteConfirmation = TypedConfirmationModel(request, names: keys.prefix(TypedConfirmationModel.listLimit).map(KeyDisplay.name), total: keys.count) {
            [weak self] in
            await self?.deleteKeys(keys, context: context) ?? nil
        }
    }

    /// Deletes `keys` in batches with the typed confirmation's yes for exactly these keys, then drops the deleted ones
    /// from the list without a rescan. Returns why it stopped early (the deleted part stays deleted), nil when done.
    func deleteKeys(_ keys: [Data], context: DataContext) async -> String? {
        let index = list.index
        var confirmed = context
        confirmed.confirmation = MultiKeyDelete.confirmation(for: keys, database: context.database)
        let report = await MultiKeyDelete.run(keys, service: await index.service, context: confirmed)
        // The list follows only while it still shows the database the keys were deleted from.
        if !report.removed.isEmpty, await index.context.database == context.database {
            await list.select(keyBytes: nil)
            await index.remove(keys: report.removed)
            list.setTotalKeys(list.totalKeys.map { max($0 - report.deleted, 0) })
            await list.reload()
        }
        return report.failure.map { Self.deleteMessage(report, $0) }
    }

    /// What stopped a multi-key delete, with how far it got.
    static func deleteMessage(_ report: MultiKeyDelete.Report, _ failure: MultiKeyDelete.Failure) -> String {
        let done = report.removed.isEmpty ? "No keys were deleted" : "Deleted \(KeyIndexFooter.grouped(report.removed.count)) of \(KeyIndexFooter.grouped(report.requested)) keys"
        switch failure {
        case .cancelled: return "\(done); the delete was stopped."
        case .server(let message): return "\(done). The server refused the next batch: \(message)"
        case .command(.command(.outcomeUnknown)), .command(.command(.timeout)):
            let batch = report.removed.isEmpty ? "The connection was lost during the first batch" : "\(done). The connection was lost during the next batch"
            return "\(batch), so whether its keys were deleted is unknown; refresh to see what is left."
        case .command(let error): return "\(done). \(EditorSession.keyActionMessage(error))"
        }
    }

    // MARK: - New key (FR-ED14)

    /// Writable profiles only. Selecting the new key reopens the editor, which would drop a draft, so unsaved changes are
    /// saved or reverted first (as for Rename).
    public var canCreateKey: Bool { !isReadOnly && editor?.hasUnsavedChanges != true }

    /// The name field's starting text: the selected folder, or the selected key's folder in the tree, plus the separator.
    public func newKeyPrefill() async -> Data {
        let index = list.index
        var folder = list.selectedFolder
        if folder == nil, list.mode == .tree, let key = list.selectedKey { folder = await index.namespaceAncestors(ofKey: key).last }
        var namespace: Data?
        if let folder { namespace = await index.namespacePath(of: folder) }
        return NewKey.prefill(namespace: namespace, separator: await index.separator)
    }

    /// Creates the key and selects it (opening its editor). Returns why it failed ("Key already exists" when the name is
    /// taken; nothing was written then); nil when created. A key the filter wouldn't list is created but not selected.
    public func createKey(_ key: Data, _ value: NewKey.Value, ttlMilliseconds: Int64?) async -> String? {
        guard canCreateKey else { return isReadOnly ? "This connection is read-only." : "Save or revert your changes first." }
        let index = list.index
        let outcome: NewKey.Outcome
        do throws(DataCommandError) {
            outcome = try await NewKey.create(key, value, ttlMilliseconds: ttlMilliseconds, service: await index.service, context: await index.context)
        } catch {
            return EditorSession.keyActionMessage(error)
        }
        guard outcome == .created else { return NewKey.existsMessage }
        let listed = await index.add(key: key, type: value.type)
        list.setTotalKeys(list.totalKeys.map { $0 + 1 })
        await list.reload()
        if listed { await list.select(keyBytes: key) }
        return nil
    }

    /// "Remove from List": drops the missing key from the loaded keys; nothing is sent to the server.
    public func removeMissingKey() async {
        guard let key = missingKey else { return }
        missingKey = nil
        await list.select(keyBytes: nil)
        await list.index.remove(key: key)
        await list.reload()
    }
}

/// The toolbar's database picker (`db0 ▾`, 08 Design → Toolbar): every database the server offers, with key counts
/// for those that have keys. Cluster mode lists db0 only.
public struct DatabasePicker: View {
    @ObservedObject var model: BrowserModel

    public init(model: BrowserModel) { self.model = model }

    public var body: some View {
        Menu {
            Picker("Database", selection: Binding(get: { model.database }, set: { database in Task { await model.selectDatabase(database) } })) {
                ForEach(model.databases.entries) { entry in
                    Text(entry.title).tag(entry.index).accessibilityLabel(entry.accessibilityLabel)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("db\(model.database)").font(Tokens.mono(12))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .padding(.horizontal, 10).frame(height: 28)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(Tokens.fg)
        .accessibilityLabel("Database")
        .accessibilityValue(model.databases.entry(model.database)?.accessibilityLabel ?? "db\(model.database)")
        .help("Switch database (⌥⌘0–9)")
    }
}

/// The key list with the "Key no longer exists" notice above its footer when the opened key is gone (FR-KB12).
public struct BrowserPane: View {
    @ObservedObject var model: BrowserModel
    let perform: (KeyIndexFooter.Action) async -> Void

    public init(model: BrowserModel, perform: @escaping (KeyIndexFooter.Action) async -> Void) { self.model = model; self.perform = perform }

    public var body: some View {
        VStack(spacing: 0) {
            KeyListPane(dataSource: model.list, filter: model.filter, perform: perform)
            if model.missingKey != nil { MissingKeyNotice(model: model) }
        }
        .sheet(item: $model.deleteConfirmation) { confirmation in
            TypedConfirmationSheet(model: confirmation) { model.deleteConfirmation = nil }
        }
    }
}

/// One quiet line: the message in words (never color alone) and the removal offered as a link.
struct MissingKeyNotice: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.warning).accessibilityHidden(true)
            Text(KeyPresence.missingMessage).foregroundStyle(Tokens.fg)
            Text("·").foregroundStyle(Tokens.muted).accessibilityHidden(true)
            Button("Remove from List") { Task { await model.removeMissingKey() } }
                .buttonStyle(.plain).foregroundStyle(Tokens.accent)
            Spacer(minLength: 0)
        }
        .font(Tokens.interface(11.5))
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Tokens.soft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(KeyPresence.missingMessage)
    }
}

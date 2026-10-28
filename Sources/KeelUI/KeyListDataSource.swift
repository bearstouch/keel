import AppKit
import KeelCore

/// A tree row. NSOutlineView tracks rows by object identity, so each folder keeps one item per child, created only
/// when the outline asks for that row: expanding a folder of 500,000 keys allocates the child list, not 500,000 items.
final class KeyListItem: NSObject {
    let child: NamespaceChild
    /// The last fetched content and the reload it belongs to; an older one is still shown until the new one lands.
    var row: KeyListRow?
    var rowStamp = -1
    /// Nil until the folder's children were fetched.
    private(set) var children: [NamespaceChild]?
    private var items: [KeyListItem?] = []

    init(child: NamespaceChild) { self.child = child }

    var folderID: NamespaceFolderID? { if case .folder(let id) = child { id } else { nil } }

    /// New children from the index; items that are still listed are kept, so expansion and selection survive.
    func setChildren(_ refs: [NamespaceChild]) {
        var existing: [NamespaceChild: KeyListItem] = [:]
        for case let item? in items { existing[item.child] = item }
        children = refs
        items = existing.isEmpty ? Array(repeating: nil, count: refs.count) : refs.map { existing[$0] }
    }

    /// Drops a collapsed folder's children, so expanding it again fetches the keys loaded since.
    func forgetChildren() { children = nil; items = [] }

    func item(at offset: Int) -> KeyListItem {
        if let item = items[offset] { return item }
        let item = KeyListItem(child: children![offset])
        items[offset] = item
        return item
    }

    /// The child item for `child`, if listed here.
    func item(for child: NamespaceChild) -> KeyListItem? { children?.firstIndex(of: child).map(item(at:)) }

    /// Items already created, for invalidating and restoring state; never forces new ones.
    var createdItems: some Sequence<KeyListItem> { items.lazy.compactMap { $0 } }
}

/// The browser's key list (FR-KB03, FR-KB04): an `NSOutlineView` for the tree and an `NSTableView` for the flat view
/// over one `KeyIndex`. Both are view based and ask only for visible rows; row content is fetched from the index in
/// batches for the visible range (plus a margin) and cached, so a million loaded keys never become a million strings.
/// The selection is a key, not a row, so ⇧⌘T keeps it: the tree expands the key's folders to reveal it.
@MainActor
public final class KeyListDataSource: NSObject, ObservableObject {
    public enum Mode: String, Sendable, Equatable { case tree, flat }

    public let index: KeyIndex
    @Published public private(set) var mode: Mode
    /// The selected key's index in `KeyIndex`; nil when nothing or a folder is selected.
    @Published public private(set) var selectedKey: Int?
    /// The selected folder (tree only; the flat view has no folders, so toggling drops it).
    @Published public private(set) var selectedFolder: NamespaceFolderID?
    /// The keys of a selection of more than one row, in row order (folders in it are skipped); empty otherwise, and
    /// `selectedKey` is nil then. Only keys shown selected are kept: a reload that can't show one drops it (FR-KB11).
    @Published public private(set) var selectedKeys: [Int] = []
    /// ⌫ in the list (FR-KB11); the browser asks for the typed confirmation.
    var onDelete: (() -> Void)?
    /// ⋯ → Delete Keys Matching… (FR-SF05); nil on read-only profiles, which don't offer it.
    @Published var onBulkDelete: (() -> Void)?
    @Published public private(set) var footer: KeyIndexFooter
    /// The database's `DBSIZE`, shown in the footer beside the loaded count (FR-KB09); nil until known.
    @Published public private(set) var totalKeys: Int?
    /// The index's status at the last reload, which the footer shows.
    private var status = KeyIndexStatus(loadedCount: 0, limit: KeyIndexConfiguration.defaultLimit, phase: .idle, mode: .manual)

    public let outlineView = KeyListOutlineView()
    public let tableView = KeyListTableView()
    public let scrollView = NSScrollView()
    /// Where the context menu copies to; tests use a private pasteboard.
    var pasteboard = NSPasteboard.general

    private let root = KeyListItem(child: .folder(.root))
    private var expanded: Set<NamespaceFolderID> = []
    private var keyCount = 0
    /// The index's restart count at the last reload: a restart invalidates cached rows and local matches by index.
    private var indexGeneration = 0
    /// Flat rows by key index with their stamp; cleared past `flatCacheLimit` so it never grows with the database.
    private var flatRows: [Int: (row: KeyListRow, stamp: Int)] = [:]
    /// Bumped by every `reload`, so content fetched for an older state is shown but refreshed.
    private var stamp = 0
    private var fetchScheduled = false
    /// A row asked for content while a fetch was out: that fetch's range was taken before the row scrolled into view.
    private var fetchAgain = false
    /// The selected key's bytes, to notice a restart that put another key at the same index.
    private var selectedKeyBytes: Data?
    /// A key to select once a page loads it: Refresh (⌘R) keeps the selection when the key comes back (FR-KB09).
    /// Any other selection, by the user or the model, drops it.
    private var pendingSelection: Data?
    /// True while the model itself changes the views' selection, so the delegate doesn't echo it back.
    private var applyingSelection = false
    /// Asked before a click or arrow key moves the selection: true holds the move (the open editor has unsaved
    /// changes, FR-ED16) and `onHeldSelection` asks the user; `applyHeldSelection()` then makes it.
    var holdsSelectionChange: (() -> Bool)?
    var onHeldSelection: (() -> Void)?
    /// The rows the held move proposed, as keys and folders: rows can shift (a page loads) while the user answers.
    private var heldSelection: (children: [NamespaceChild], generation: Int)?
    private var releasingHeldSelection = false
    /// The index generation `selectedKeys` was taken at: their indices name other keys after a restart or removal.
    private var selectedKeysGeneration = 0
    /// The local filter's text as typed; empty when it's off (FR-KB05).
    @Published public private(set) var localQuery = ""
    /// Keys matching the local filter so far, in index order; nil when it's off. While on, the flat table lists
    /// only these, whatever the mode, since a filtered tree would hide matches inside collapsed folders.
    private(set) var localMatches: [Int]?
    /// Keys `0..<localSearched` have been searched; the next chunk starts here.
    private var localSearched = 0
    /// Bumped by every new search; a chunk landing for an older one is dropped.
    private var localSearchID = 0
    /// Fills types, TTLs and sizes for the rows in view (FR-KB06, FR-KB07); nil lists names only.
    public let metadataLoader: RowMetadataLoader?
    /// ⋯ → Show Sizes: measures the visible rows with `MEMORY USAGE` (FR-KB07). Off until asked for.
    @Published public private(set) var showsSizes = false
    /// Redraws visible TTLs once a second from their deadlines; it never sends a command (NFR-PF07).
    private var countdown: Task<Void, Never>?

    static let rowHeight: CGFloat = 32
    static let fetchMargin = 64
    static let flatCacheLimit = 4_096

    public init(index: KeyIndex, mode: Mode = .tree, metadataLoader: RowMetadataLoader? = nil) {
        self.index = index; self.mode = mode; self.metadataLoader = metadataLoader
        footer = KeyIndexFooter(status: status)
        super.init()
        configure(outlineView); configure(tableView)
        outlineView.indentationPerLevel = 18
        let column = Self.column()
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        tableView.addTableColumn(Self.column())
        outlineView.dataSource = self; outlineView.delegate = self
        tableView.dataSource = self; tableView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Tokens.NS.bg
        scrollView.documentView = activeView
        scrollView.setAccessibilityLabel("Keys")
        if metadataLoader != nil {
            // Rows scrolled in from the fetch margin are cached already and ask for no content, so scrolling itself
            // asks for their metadata (FR-KB06).
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(visibleRowsMoved), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            // Holds the list weakly: once it is gone, the loop ends at its next tick.
            countdown = Task { [weak self] in
                while (try? await Task.sleep(for: .seconds(1))) != nil {
                    guard let self else { return }
                    self.tickCountdowns()
                }
            }
        }
    }

    private func configure(_ view: NSTableView) {
        (view as? KeyListOutlineView)?.owner = self; (view as? KeyListTableView)?.owner = self
        view.headerView = nil
        view.style = .plain
        view.rowHeight = Self.rowHeight
        view.intercellSpacing = .zero
        view.backgroundColor = Tokens.NS.bg
        // One column that always spans the pane, so counts, TTLs and badges stay at its trailing edge.
        view.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // Type-select would ask for the name of every row; with lazily fetched names it can't work (KEEL-023 filters).
        view.allowsTypeSelect = false
        view.allowsMultipleSelection = true
        view.usesAutomaticRowHeights = false
        view.menu = NSMenu()
        view.menu?.delegate = self
        view.setAccessibilityLabel("Keys")
        // The plain style draws no focus on its own; the views draw a ring inside the pane instead (NFR-AX02).
        view.focusRingType = .exterior
    }

    private static func column() -> NSTableColumn {
        let column = NSTableColumn(identifier: KeyListCellView.identifier)
        // The header is hidden; VoiceOver still names the column.
        column.title = "Key"
        column.resizingMask = .autoresizingMask
        return column
    }

    /// The view on screen: the flat table in flat mode or while the local filter is on, the outline otherwise.
    public var activeView: NSTableView { showsTable ? tableView : outlineView }

    private var showsTable: Bool { mode == .flat || localMatches != nil }
    /// The layout on screen, which differs from `mode` while the local filter forces the flat table.
    private var shownMode: Mode { showsTable ? .flat : .tree }

    /// Rows the active view lists: every visible tree row (expanded folders' children included), or every key.
    public var visibleRowCount: Int { activeView.numberOfRows }

    // MARK: - Loading

    /// Re-reads the index after a page loaded, a restart or a separator change: counts, the footer, the root and
    /// every expanded folder. Content already shown stays until its fresh copy arrives, so rows don't flicker.
    public func reload() async {
        stamp += 1
        let reloadStamp = stamp
        let status = await index.status
        let count = await index.count
        // Read after the count: a restart between the two resets here, and the next reload re-reads the count.
        let generation = await index.generation
        let rootChildren = await index.namespaceChildren(of: .root)
        var loaded: [NamespaceFolderID: [NamespaceChild]] = [:]
        for id in expanded { loaded[id] = await index.namespaceChildren(of: id) }
        let selectionStillValid = await isSelectionValid()
        let pending = pendingSelection
        let found = if let pending { await index.index(of: pending) } else { Int?.none }
        // A newer reload started while this one awaited the index; it owns the views now.
        guard reloadStamp == stamp else { return }

        self.status = status
        footer = KeyIndexFooter(status: status, totalKeys: totalKeys)
        // After a restart the cached names belong to other keys, and earlier local matches point at other keys too,
        // so the local search starts over. The index may already hold more keys than before by now.
        if count < keyCount || generation != indexGeneration {
            flatRows.removeAll()
            selectedKeys = []
            if localMatches != nil { localMatches = []; localSearched = 0 }
        }
        keyCount = count; indexGeneration = generation
        root.setChildren(rootChildren)
        // Re-expand only folders still reachable from the root; IDs from an earlier tree drop out here. Collapsed
        // folders forget their children, which this reload didn't refresh.
        var stillExpanded: Set<NamespaceFolderID> = []
        func restore(_ item: KeyListItem) {
            for child in item.createdItems {
                guard let id = child.folderID else { continue }
                guard expanded.contains(id), child.children != nil else { child.forgetChildren(); continue }
                // Not in `loaded`: expanded while this reload awaited the index, so its children are as recent.
                if let refs = loaded[id] { child.setChildren(refs) }
                stillExpanded.insert(id)
                restore(child)
            }
        }
        // Expanded folders not created yet can't be expanded on screen, so walking created items is enough.
        restore(root)
        expanded = stillExpanded
        if !selectionStillValid { selectedKey = nil; selectedKeyBytes = nil; selectedFolder = nil }
        if selectedKeysGeneration != generation { selectedKeys = [] }
        // The pending key is loaded now (and nothing else was selected meanwhile): it becomes the selection.
        if let pending, let found, pendingSelection == pending, found < count {
            pendingSelection = nil
            selectedKey = found; selectedKeyBytes = pending; selectedFolder = nil
        }

        withSelectionApplied {
            tableView.reloadData()
            outlineView.reloadData()
            expandRestored(root)
        }
        // A pending key that just became the selection may sit in a collapsed folder or off screen: reveal it.
        if let pending, found != nil, selectedKeyBytes == pending { await reveal() } else { applySelection() }
        // Pages loaded since the last search are searched now; a search still running is superseded and resumes here.
        if localMatches != nil { await searchLocally() }
    }

    /// The footer's total: the database's `DBSIZE`, or nil when it isn't known (a failed or refused `DBSIZE`).
    public func setTotalKeys(_ total: Int?) {
        totalKeys = total
        footer = KeyIndexFooter(status: status, totalKeys: total)
    }

    /// Selects the key with these bytes: now if it is loaded, otherwise as soon as a reload finds it (a refresh keeps
    /// the selection this way, FR-KB09). Nil clears the selection and any pending key.
    public func select(keyBytes: Data?) async {
        selectedKeys = []
        guard let keyBytes else {
            pendingSelection = nil; selectedKey = nil; selectedKeyBytes = nil; selectedFolder = nil
            applySelection()
            return
        }
        if let found = await index.index(of: keyBytes), found < keyCount {
            await select(key: found)
        } else {
            selectedKey = nil; selectedKeyBytes = nil; selectedFolder = nil
            pendingSelection = keyBytes
            applySelection()
        }
    }

    /// The key waiting for a page to load it before it is selected; nil when none.
    var pendingKey: Data? { pendingSelection }

    /// The selected key's bytes, read from the index; nil when nothing or a folder is selected.
    public func selectedKeyName() async -> Data? {
        guard let key = selectedKey else { return nil }
        if let selectedKeyBytes { return selectedKeyBytes }
        return await loadedKey(key)
    }

    /// The bytes of `selectedKeys`; nil when the index changed since they were selected (the keys moved).
    public func selectedKeyNames() async -> [Data]? {
        guard !selectedKeys.isEmpty else { return [] }
        return await index.keys(at: selectedKeys, generation: selectedKeysGeneration)
    }

    // MARK: - Local filter

    /// The quick local filter (FR-KB05): substring over the loaded keys, ASCII case ignored, never sent to the server.
    /// Matches show chunk by chunk, so the first ones appear long before a million keys are searched (AC3).
    public func setLocalFilter(_ text: String) async {
        guard text != localQuery else { return }
        localQuery = text
        // Rows change meaning when the filter does; a multi-selection would name keys no longer shown together.
        selectedKeys = []
        let wasOn = localMatches != nil
        localMatches = LocalKeyQuery(text).isEmpty ? nil : []
        localSearched = 0
        if wasOn != (localMatches != nil) { showActiveView() }
        tableView.reloadData()
        applySelection()
        // Turning the filter off bumps the search ID so a chunk still in flight is dropped.
        if localMatches != nil { await searchLocally() } else { localSearchID += 1 }
    }

    /// Searches from `localSearched` to the loaded count, one chunk per call to the index, showing matches as they come.
    private func searchLocally() async {
        localSearchID += 1
        let searchID = localSearchID
        let query = LocalKeyQuery(localQuery)
        while localSearchID == searchID, localSearched < keyCount {
            // Never past `keyCount`: keys the index loaded since the last reload aren't rows yet; the next reload resumes
            // the search from here and finds them.
            let chunk = await index.localMatches(query, from: localSearched, chunk: min(KeyIndex.localSearchChunk, keyCount - localSearched))
            // A newer search or a cleared filter owns the list now.
            // A restart since the last reload leaves fewer keys than `keyCount`: stop rather than spin; the reload
            // that follows starts the search over.
            guard localSearchID == searchID, localMatches != nil, chunk.searchedThrough > localSearched else { return }
            localMatches?.append(contentsOf: chunk.indices)
            localSearched = chunk.searchedThrough
            withSelectionApplied { tableView.noteNumberOfRowsChanged() }
            applySelection()
        }
    }

    /// Puts the active view in the scroll view, keeping its focus.
    private func showActiveView() {
        guard scrollView.documentView !== activeView else { return }
        let hadFocus = scrollView.documentView.map { $0.window?.firstResponder === $0 } ?? false
        scrollView.documentView = activeView
        activeView.sizeLastColumnToFit()
        if hadFocus { activeView.window?.makeFirstResponder(activeView) }
    }

    /// The key a flat row shows: the row itself, or the row-th local match.
    private func flatKey(atRow row: Int) -> Int? {
        guard row >= 0 else { return nil }
        if let localMatches { return row < localMatches.count ? localMatches[row] : nil }
        return row < keyCount ? row : nil
    }

    /// The flat row showing `key`; matches are in index order, so a binary search finds it.
    private func flatRow(ofKey key: Int) -> Int? {
        guard let localMatches else { return key < keyCount ? key : nil }
        var low = 0, high = localMatches.count
        while low < high {
            let mid = (low + high) / 2
            if localMatches[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low < localMatches.count && localMatches[low] == key ? low : nil
    }

    private func isSelectionValid() async -> Bool {
        if let folder = selectedFolder { return await index.namespacePath(of: folder) != nil }
        guard let key = selectedKey else { return true }
        guard let current = await loadedKey(key) else { return false }
        return selectedKeyBytes.map { $0 == current } ?? true
    }

    /// The key's bytes in one call, nil past the loaded range: the index may have restarted since the row was shown,
    /// and a count read in a separate call can be stale by the time the key is.
    private func loadedKey(_ key: Int) async -> Data? { await index.keys(in: key..<key + 1).first }

    private func expandRestored(_ item: KeyListItem) {
        for child in item.createdItems where child.folderID.map(expanded.contains) == true {
            outlineView.expandItem(child)
            expandRestored(child)
        }
    }

    /// Fetches a folder's children, then expands it (a disclosure click, → or a reveal).
    func expand(_ item: KeyListItem) async {
        guard let id = item.folderID else { return }
        if item.children == nil {
            let refs = await index.namespaceChildren(of: id)
            if item.children == nil { item.setChildren(refs) }
        }
        expanded.insert(id)
        outlineView.expandItem(item)
    }

    // MARK: - Mode and selection

    /// ⇧⌘T: switches views and keeps the selected key (FR-KB03).
    public func toggleMode() async { await setMode(mode == .tree ? .flat : .tree) }

    public func setMode(_ mode: Mode) async {
        guard mode != self.mode else { return }
        if mode == .flat { selectedFolder = nil }
        self.mode = mode
        showActiveView()
        await reveal()
    }

    /// Selects a key and reveals it in the active view.
    public func select(key: Int) async {
        selectedKey = key; selectedFolder = nil; selectedKeyBytes = nil; pendingSelection = nil; selectedKeys = []
        let bytes = await bytes(of: .key(key))
        // A click during the await owns the selection now; don't pin this key's bytes to it.
        guard selectedKey == key else { return }
        selectedKeyBytes = bytes
        await reveal()
    }

    /// Makes the selected key visible: in the tree, expands its folders first.
    private func reveal() async {
        if !showsTable, let key = selectedKey {
            var parent = root
            for folder in await index.namespaceAncestors(ofKey: key) {
                guard let item = parent.item(for: .folder(folder)) else { break }
                await expand(item)
                parent = item
            }
        }
        applySelection()
        let row = activeView.selectedRow
        if row >= 0 { activeView.scrollRowToVisible(row) }
    }

    /// Shows the model's selection in the active view (nothing selected when it isn't visible).
    private func applySelection() {
        guard selectedKeys.isEmpty else { applyKeySelection(); return }
        var row = -1
        switch shownMode {
        case .flat:
            if let key = selectedKey, let keyRow = flatRow(ofKey: key), keyRow < tableView.numberOfRows { row = keyRow }
        case .tree:
            if let target = selectedKey.map(NamespaceChild.key) ?? selectedFolder.map(NamespaceChild.folder), let item = treeItem(for: target) {
                row = outlineView.row(forItem: item)
            }
        }
        withSelectionApplied {
            if row >= 0 { activeView.selectRowIndexes([row], byExtendingSelection: false) } else { activeView.deselectAll(nil) }
        }
    }

    /// Shows `selectedKeys` in the active view, keeping only the keys it can show: what is deleted is what is seen.
    private func applyKeySelection() {
        var rows = IndexSet(), shown: [Int] = []
        switch shownMode {
        case .flat:
            for key in selectedKeys {
                guard let row = flatRow(ofKey: key), row < tableView.numberOfRows else { continue }
                rows.insert(row); shown.append(key)
            }
        case .tree:
            // One walk of the created items finds them all; only items under expanded folders have rows.
            let wanted = Set(selectedKeys)
            var found: [Int: KeyListItem] = [:]
            func search(_ item: KeyListItem) {
                for created in item.createdItems {
                    if case .key(let key) = created.child, wanted.contains(key) { found[key] = created }
                    if created.children != nil, outlineView.isItemExpanded(created) { search(created) }
                }
            }
            search(root)
            for key in selectedKeys {
                guard let item = found[key] else { continue }
                let row = outlineView.row(forItem: item)
                if row >= 0 { rows.insert(row); shown.append(key) }
            }
        }
        // Fewer than two left: nothing stays selected rather than a key the user didn't pick alone.
        if shown.count != selectedKeys.count { selectedKeys = shown.count > 1 ? shown : [] }
        if selectedKeys.isEmpty { rows = [] }
        withSelectionApplied { activeView.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    /// The created item for `child` among the visible rows' parents.
    private func treeItem(for child: NamespaceChild) -> KeyListItem? {
        func search(_ item: KeyListItem) -> KeyListItem? {
            for created in item.createdItems {
                if created.child == child { return created }
                if created.children != nil, outlineView.isItemExpanded(created), let found = search(created) { return found }
            }
            return nil
        }
        return search(root)
    }

    private func withSelectionApplied(_ body: () -> Void) {
        let previous = applyingSelection
        applyingSelection = true; body(); applyingSelection = previous
    }

    /// A move the user proposes goes through now, or is held while the browser asks about unsaved changes.
    func proposedSelection(_ proposed: IndexSet, in view: NSTableView) -> IndexSet {
        guard !applyingSelection, !releasingHeldSelection, view === activeView, proposed != view.selectedRowIndexes, holdsSelectionChange?() == true else {
            return proposed
        }
        heldSelection = (proposed.compactMap(child(atRow:)), indexGeneration)
        onHeldSelection?()
        return view.selectedRowIndexes
    }

    /// The user saved or discarded: the held move is made, unless the list restarted since (its rows name other keys).
    func applyHeldSelection() {
        guard let held = heldSelection else { return }
        heldSelection = nil
        guard held.generation == indexGeneration else { return }
        var rows = IndexSet()
        for child in held.children {
            switch (child, shownMode) {
            case (.key(let key), .flat): if let row = flatRow(ofKey: key), row < tableView.numberOfRows { rows.insert(row) }
            case (_, .tree): if let row = treeItem(for: child).map(outlineView.row(forItem:)), row >= 0 { rows.insert(row) }
            case (.folder, .flat): break
            }
        }
        releasingHeldSelection = true
        activeView.selectRowIndexes(rows, byExtendingSelection: false)
        releasingHeldSelection = false
    }

    /// Cancel: the selection stays where it was.
    func dropHeldSelection() { heldSelection = nil }

    /// The user moved the selection with the mouse or keyboard.
    private func selectionChanged(in view: NSTableView) {
        guard !applyingSelection, view === activeView else { return }
        pendingSelection = nil
        if view.selectedRowIndexes.count > 1 {
            // Several rows: the keys among them; the editor closes (no single selected key).
            var keys: [Int] = []
            for row in view.selectedRowIndexes { if case .key(let key)? = child(atRow: row) { keys.append(key) } }
            // A folder and one key isn't a multi-key selection: nothing is open and ⌫ does nothing.
            selectedKeys = keys.count > 1 ? keys : []
            selectedKeysGeneration = indexGeneration
            selectedKey = nil; selectedFolder = nil; selectedKeyBytes = nil
            return
        }
        selectedKeys = []
        let child = self.child(atRow: view.selectedRow)
        switch child {
        case .key(let key)?: selectedKey = key; selectedFolder = nil
        case .folder(let id)?: selectedKey = nil; selectedFolder = id
        case nil: selectedKey = nil; selectedFolder = nil
        }
        selectedKeyBytes = nil
        guard case .key(let key)? = child else { return }
        Task {
            let bytes = await loadedKey(key)
            if selectedKey == key { selectedKeyBytes = bytes }
        }
    }

    func child(atRow row: Int) -> NamespaceChild? {
        guard row >= 0 else { return nil }
        return showsTable ? flatKey(atRow: row).map(NamespaceChild.key) : (outlineView.item(atRow: row) as? KeyListItem)?.child
    }

    /// The cached content of a row in the active view; nil until fetched. Its TTL and size are as stored, not as shown
    /// (`presented`).
    func row(at row: Int) -> KeyListRow? {
        showsTable ? flatKey(atRow: row).flatMap { flatRows[$0]?.row } : (outlineView.item(atRow: row) as? KeyListItem)?.row
    }

    // MARK: - Content

    /// Fetches content for the visible rows on the next turn of the run loop; many cells asking at once share one fetch.
    private func requestContent() {
        guard !fetchScheduled else { fetchAgain = true; return }
        fetchScheduled = true
        Task { await fetchVisibleContent() }
    }

    /// Loads names, counts and types for the visible range plus a margin, then reloads only those rows.
    func fetchVisibleContent() async {
        // The range is taken now; a row that asks while the index answers (a scroll) needs one more pass.
        fetchAgain = false
        defer {
            fetchScheduled = false
            if fetchAgain { fetchAgain = false; requestContent() }
        }
        let view = activeView
        let visible = view.rows(in: view.visibleRect)
        requestMetadata(forRows: Self.onScreen(view))
        let rows = max(visible.location - Self.fetchMargin, 0)..<min(visible.location + max(visible.length, 1) + Self.fetchMargin, view.numberOfRows)
        guard !rows.isEmpty else { return }
        let fetchStamp = stamp
        switch shownMode {
        case .flat:
            // The cache is by key, so rows keep their content when the local filter changes which row shows a key.
            let missing = rows.compactMap(flatKey(atRow:)).filter { flatRows[$0]?.stamp != fetchStamp }
            guard !missing.isEmpty else { return }
            let entries = await index.namespaceEntries(missing.map(NamespaceChild.key), fullNames: true)
            if flatRows.count + entries.count > Self.flatCacheLimit { flatRows.removeAll(keepingCapacity: true) }
            for entry in entries {
                guard case .key(let key) = entry.child else { continue }
                flatRows[key] = (KeyListRow(entry), fetchStamp)
            }
            // The user may have toggled views or changed the local filter while the fetch was out: redraw the rows that
            // show a fetched key now; the other view reloads on its own.
            guard showsTable else { return }
            let changed = IndexSet(rows.filter { row in flatKey(atRow: row).map { flatRows[$0]?.stamp == fetchStamp } ?? false })
            tableView.reloadData(forRowIndexes: changed.filteredIndexSet { $0 < tableView.numberOfRows }, columnIndexes: [0])
        case .tree:
            let missing = rows.compactMap { row in (outlineView.item(atRow: row) as? KeyListItem).map { (row, $0) } }.filter { $0.1.rowStamp != fetchStamp }
            guard !missing.isEmpty else { return }
            let entries = await index.namespaceEntries(missing.map(\.1.child))
            var byChild: [NamespaceChild: NamespaceEntry] = [:]
            for entry in entries { byChild[entry.child] = entry }
            var changed = IndexSet()
            for (row, item) in missing {
                guard let entry = byChild[item.child] else { continue }
                item.row = KeyListRow(entry); item.rowStamp = fetchStamp
                // `row(forItem:)` is slow in a large outline; a row that moved while the fetch was out is redrawn when it
                // scrolls back into view, since its content is cached on the item.
                if !showsTable, row < outlineView.numberOfRows, outlineView.item(atRow: row) as? KeyListItem === item { changed.insert(row) }
            }
            if !showsTable { outlineView.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
        }
    }

    private func cell(in view: NSTableView, row: KeyListRow?, stale: Bool) -> NSView {
        let cell = view.makeView(withIdentifier: KeyListCellView.identifier, owner: nil) as? KeyListCellView ?? KeyListCellView()
        cell.show(row.map(presented))
        if row == nil || stale { requestContent() }
        return cell
    }

    // MARK: - Row metadata

    /// A cached row as shown now: TTL counted down to this moment, size only while Show Sizes is on.
    private func presented(_ row: KeyListRow) -> KeyListRow {
        row.presented(at: metadataLoader?.nowMilliseconds() ?? 0, showsSizes: showsSizes)
    }

    /// The keys among `rows` of the active view; folders need no metadata.
    func keys(inRows rows: Range<Int>) -> [Int] {
        rows.clamped(to: 0..<activeView.numberOfRows).compactMap { row in if case .key(let key)? = child(atRow: row) { key } else { nil } }
    }

    /// Asks the loader for the visible keys' metadata — only rows on screen, not the fetch margin (FR-KB07) — and
    /// redraws the rows it changed. The loader throttles and coalesces, and sends nothing when they are all known.
    private func requestMetadata(forRows rows: Range<Int>) {
        guard let metadataLoader else { return }
        let keys = keys(inRows: rows)
        guard !keys.isEmpty else { return }
        // Cached rows still missing metadata the index may hold by now (fetched while they were off screen) are
        // redrawn too. Redrawing never asks again, so a failing server isn't asked in a loop.
        let behind = rows.clamped(to: 0..<activeView.numberOfRows).compactMap { row -> Int? in
            guard let cached = self.row(at: row), case .key(let key) = cached.child, cached.needsMetadata(showsSizes: showsSizes) else { return nil }
            return key
        }
        Task {
            let changed = Set(await metadataLoader.load(keys)).union(behind)
            if !changed.isEmpty { await refreshRows(ofKeys: changed) }
        }
    }

    @objc private func visibleRowsMoved(_ notification: Notification) { requestMetadata(forRows: Self.onScreen(activeView)) }

    /// Re-reads the index for the cached rows showing `keys` and redraws those on screen.
    func refreshRows(ofKeys keys: Set<Int>) async {
        let fetchStamp = stamp
        let entries = await index.namespaceEntries(keys.sorted().map(NamespaceChild.key), fullNames: true)
        // Only what changed is copied in, so a row keeps its tree name and a reload in between still wins.
        guard fetchStamp == stamp else { return }
        var changedRows = IndexSet()
        for entry in entries {
            guard case .key(let key) = entry.child else { continue }
            let fresh = KeyListRow(entry)
            flatRows[key]?.row.adopt(metadataOf: fresh)
            if showsTable, let row = flatRow(ofKey: key) { changedRows.insert(row) }
        }
        if !showsTable {
            for row in Self.onScreen(outlineView) {
                guard let item = outlineView.item(atRow: row) as? KeyListItem, case .key(let key) = item.child, keys.contains(key),
                    let entry = entries.first(where: { $0.child == item.child })
                else { continue }
                item.row?.adopt(metadataOf: KeyListRow(entry))
                changedRows.insert(row)
            }
        }
        let view = activeView
        view.reloadData(forRowIndexes: changedRows.filteredIndexSet { $0 < view.numberOfRows }, columnIndexes: [0])
    }

    /// ⋯ → Show Sizes. On, the visible rows are measured; off, sizes hide and nothing is sent.
    public func setShowsSizes(_ on: Bool) async {
        guard on != showsSizes else { return }
        showsSizes = on
        await metadataLoader?.setShowsSizes(on)
        redrawVisibleRows()
        if on { requestContent() }
    }

    /// Once a second: re-derives the visible rows' TTLs from their deadlines, locally (AC2). Expiring rows only.
    func tickCountdowns() {
        let view = activeView
        for row in Self.onScreen(view) {
            guard let cached = self.row(at: row), case .expires = cached.expiry,
                let cell = view.view(atColumn: 0, row: row, makeIfNecessary: false) as? KeyListCellView
            else { continue }
            cell.show(presented(cached))
        }
    }

    private func redrawVisibleRows() {
        let view = activeView
        view.reloadData(forRowIndexes: IndexSet(integersIn: Self.onScreen(view)), columnIndexes: [0])
    }

    /// The rows inside the view's visible rect: no fetch margin.
    private static func onScreen(_ view: NSTableView) -> Range<Int> {
        let visible = view.rows(in: view.visibleRect)
        return visible.location..<visible.location + visible.length
    }

    // MARK: - Context menu

    /// ⌫ (backspace, 0x7F) and ⌦ (forward delete, a function-key code point).
    private static let deleteCharacters: [Character] = [Character(UnicodeScalar(UInt8(NSDeleteCharacter))), Character(UnicodeScalar(NSDeleteFunctionKey)!)]

    /// ⌫ or ⌦ without modifiers on a multi-key selection asks to delete it (FR-KB11); other keys go to the view.
    func handlesDelete(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, let typed = event.charactersIgnoringModifiers?.first,
            Self.deleteCharacters.contains(typed), selectedKeys.count > 1, let onDelete
        else { return false }
        onDelete()
        return true
    }

    /// The context menu of a row: copy the name in either form; folders also expand or collapse. A row of a multi-key
    /// selection offers the selection's actions instead: copy the names, delete them (FR-KB11).
    func menuItems(forRow row: Int) -> [NSMenuItem] {
        if selectedKeys.count > 1, activeView.selectedRowIndexes.contains(row) {
            let count = KeyIndexFooter.grouped(selectedKeys.count)
            var items = [menuItem("Copy \(count) Key Names", represented: selectedKeys, action: #selector(copySelectedNames(_:)))]
            if onDelete != nil {
                items.append(.separator())
                items.append(menuItem("Delete \(count) Keys…", represented: selectedKeys, action: #selector(deleteSelection(_:))))
            }
            return items
        }
        guard let child = child(atRow: row) else { return [] }
        var items: [NSMenuItem] = []
        if case .folder = child, let item = outlineView.item(atRow: row) as? KeyListItem {
            let expanded = outlineView.isItemExpanded(item)
            items.append(menuItem(expanded ? "Collapse" : "Expand", represented: item, action: #selector(toggleExpansion(_:))))
            items.append(.separator())
            items.append(menuItem("Copy Path", represented: child, action: #selector(copyName(_:))))
        } else {
            items.append(menuItem("Copy Key Name", represented: child, action: #selector(copyName(_:))))
            items.append(menuItem("Copy as redis-cli Argument", represented: child, action: #selector(copyArgument(_:))))
        }
        return items
    }

    private func menuItem(_ title: String, represented: Any, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.representedObject = represented
        return item
    }

    @objc private func toggleExpansion(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? KeyListItem else { return }
        if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { Task { await expand(item) } }
    }

    @objc private func copyName(_ sender: NSMenuItem) { copy(sender, as: KeyDisplay.name) }

    /// One name per line, in row order.
    @objc private func copySelectedNames(_ sender: NSMenuItem) {
        Task {
            guard let names = await selectedKeyNames(), !names.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.setString(names.map(KeyDisplay.name).joined(separator: "\n"), forType: .string)
        }
    }

    @objc private func deleteSelection(_ sender: NSMenuItem) { onDelete?() }

    @objc private func copyArgument(_ sender: NSMenuItem) { copy(sender, as: KeyDisplay.redisCliArgument) }

    /// The original bytes: a key's full name or a folder's full path.
    func bytes(of child: NamespaceChild) async -> Data? {
        switch child {
        case .key(let key): return await loadedKey(key)
        case .folder(let id): return await index.namespacePath(of: id)
        }
    }

    /// Re-reads the bytes rather than copying the row's text: the row holds the escaped leaf, not the full name.
    private func copy(_ sender: NSMenuItem, as format: @escaping @Sendable (Data) -> String) {
        guard let child = sender.representedObject as? NamespaceChild else { return }
        Task {
            guard let bytes = await bytes(of: child) else { return }
            pasteboard.clearContents()
            pasteboard.setString(format(bytes), forType: .string)
        }
    }
}

// MARK: - Tree

extension KeyListDataSource: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? KeyListItem) ?? root).children?.count ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? KeyListItem) ?? root).item(at: index)
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? KeyListItem)?.folderID != nil }

    /// Children are fetched first; the folder expands when they land.
    public func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let item = item as? KeyListItem else { return false }
        if item.children != nil { return true }
        Task { await expand(item) }
        return false
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if let id = (notification.userInfo?["NSObject"] as? KeyListItem)?.folderID { expanded.insert(id) }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let id = (notification.userInfo?["NSObject"] as? KeyListItem)?.folderID { expanded.remove(id) }
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let item = item as? KeyListItem
        return cell(in: outlineView, row: item?.row, stale: item?.rowStamp != stamp)
    }

    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { KeyListRowView() }

    public func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        proposedSelection(proposedSelectionIndexes, in: outlineView)
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) { (notification.object as? NSTableView).map(selectionChanged) }
}

// MARK: - Flat

extension KeyListDataSource: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        // NSOutlineView is an NSTableView too, but it asks its own data source methods.
        tableView === self.tableView ? localMatches?.count ?? keyCount : 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cached = flatKey(atRow: row).flatMap { flatRows[$0] }
        return cell(in: tableView, row: cached?.row, stale: cached?.stamp != stamp)
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { KeyListRowView() }

    public func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        proposedSelection(proposedSelectionIndexes, in: tableView)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { (notification.object as? NSTableView).map(selectionChanged) }
}

// MARK: - Menu

extension KeyListDataSource: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = menuItems(forRow: activeView.clickedRow)
    }
}

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
    @Published public private(set) var footer: KeyIndexFooter

    public let outlineView = KeyListOutlineView()
    public let tableView = KeyListTableView()
    public let scrollView = NSScrollView()
    /// Where the context menu copies to; tests use a private pasteboard.
    var pasteboard = NSPasteboard.general

    private let root = KeyListItem(child: .folder(.root))
    private var expanded: Set<NamespaceFolderID> = []
    private var keyCount = 0
    /// Flat rows by key index with their stamp; cleared past `flatCacheLimit` so it never grows with the database.
    private var flatRows: [Int: (row: KeyListRow, stamp: Int)] = [:]
    /// Bumped by every `reload`, so content fetched for an older state is shown but refreshed.
    private var stamp = 0
    private var fetchScheduled = false
    /// A row asked for content while a fetch was out: that fetch's range was taken before the row scrolled into view.
    private var fetchAgain = false
    /// The selected key's bytes, to notice a restart that put another key at the same index.
    private var selectedKeyBytes: Data?
    /// True while the model itself changes the views' selection, so the delegate doesn't echo it back.
    private var applyingSelection = false

    static let rowHeight: CGFloat = 32
    static let fetchMargin = 64
    static let flatCacheLimit = 4_096

    public init(index: KeyIndex, mode: Mode = .tree) {
        self.index = index; self.mode = mode
        footer = KeyIndexFooter(status: KeyIndexStatus(loadedCount: 0, limit: KeyIndexConfiguration.defaultLimit, phase: .idle, mode: .manual))
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
        view.allowsMultipleSelection = false
        view.usesAutomaticRowHeights = false
        view.menu = NSMenu()
        view.menu?.delegate = self
        view.setAccessibilityLabel("Keys")
    }

    private static func column() -> NSTableColumn {
        let column = NSTableColumn(identifier: KeyListCellView.identifier)
        column.resizingMask = .autoresizingMask
        return column
    }

    /// The view on screen for the current mode.
    public var activeView: NSTableView { mode == .tree ? outlineView : tableView }

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
        let rootChildren = await index.namespaceChildren(of: .root)
        var loaded: [NamespaceFolderID: [NamespaceChild]] = [:]
        for id in expanded { loaded[id] = await index.namespaceChildren(of: id) }
        let selectionStillValid = await isSelectionValid()
        // A newer reload started while this one awaited the index; it owns the views now.
        guard reloadStamp == stamp else { return }

        footer = KeyIndexFooter(status: status)
        // Fewer keys than before means a restart: the cached names belong to other keys now.
        if count < keyCount { flatRows.removeAll() }
        keyCount = count
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

        withSelectionApplied {
            tableView.reloadData()
            outlineView.reloadData()
            expandRestored(root)
        }
        applySelection()
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
        let hadFocus = activeView.window?.firstResponder === activeView
        if mode == .flat { selectedFolder = nil }
        self.mode = mode
        scrollView.documentView = activeView
        activeView.sizeLastColumnToFit()
        if hadFocus { activeView.window?.makeFirstResponder(activeView) }
        await reveal()
    }

    /// Selects a key and reveals it in the active view.
    public func select(key: Int) async {
        selectedKey = key; selectedFolder = nil; selectedKeyBytes = nil
        let bytes = await bytes(of: .key(key))
        // A click during the await owns the selection now; don't pin this key's bytes to it.
        guard selectedKey == key else { return }
        selectedKeyBytes = bytes
        await reveal()
    }

    /// Makes the selected key visible: in the tree, expands its folders first.
    private func reveal() async {
        if mode == .tree, let key = selectedKey {
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
        var row = -1
        switch mode {
        case .flat:
            if let key = selectedKey, key < tableView.numberOfRows { row = key }
        case .tree:
            if let target = selectedKey.map(NamespaceChild.key) ?? selectedFolder.map(NamespaceChild.folder), let item = treeItem(for: target) {
                row = outlineView.row(forItem: item)
            }
        }
        withSelectionApplied {
            if row >= 0 { activeView.selectRowIndexes([row], byExtendingSelection: false) } else { activeView.deselectAll(nil) }
        }
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

    /// The user moved the selection with the mouse or keyboard.
    private func selectionChanged(in view: NSTableView) {
        guard !applyingSelection, view === activeView else { return }
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
        switch mode {
        case .flat: return row < keyCount ? .key(row) : nil
        case .tree: return (outlineView.item(atRow: row) as? KeyListItem)?.child
        }
    }

    /// The cached content of a row in the active view; nil until fetched.
    func row(at row: Int) -> KeyListRow? {
        switch mode {
        case .flat: return flatRows[row]?.row
        case .tree: return (outlineView.item(atRow: row) as? KeyListItem)?.row
        }
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
        let rows = max(visible.location - Self.fetchMargin, 0)..<min(visible.location + max(visible.length, 1) + Self.fetchMargin, view.numberOfRows)
        guard !rows.isEmpty else { return }
        let fetchStamp = stamp
        switch mode {
        case .flat:
            let missing = rows.filter { flatRows[$0]?.stamp != fetchStamp }
            guard !missing.isEmpty else { return }
            let entries = await index.namespaceEntries(missing.map(NamespaceChild.key), fullNames: true)
            if flatRows.count + entries.count > Self.flatCacheLimit { flatRows.removeAll(keepingCapacity: true) }
            var changed = IndexSet()
            for entry in entries {
                guard case .key(let key) = entry.child else { continue }
                flatRows[key] = (KeyListRow(entry), fetchStamp); changed.insert(key)
            }
            // The user may have toggled views while the fetch was out; the other view reloads on its own.
            if mode == .flat { tableView.reloadData(forRowIndexes: changed.filteredIndexSet { $0 < tableView.numberOfRows }, columnIndexes: [0]) }
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
                if mode == .tree, row < outlineView.numberOfRows, outlineView.item(atRow: row) as? KeyListItem === item { changed.insert(row) }
            }
            if mode == .tree { outlineView.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
        }
    }

    private func cell(in view: NSTableView, row: KeyListRow?, stale: Bool) -> NSView {
        let cell = view.makeView(withIdentifier: KeyListCellView.identifier, owner: nil) as? KeyListCellView ?? KeyListCellView()
        cell.show(row)
        if row == nil || stale { requestContent() }
        return cell
    }

    // MARK: - Context menu

    /// The context menu of a row: copy the name in either form; folders also expand or collapse.
    func menuItems(forRow row: Int) -> [NSMenuItem] {
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

    public func outlineViewSelectionDidChange(_ notification: Notification) { (notification.object as? NSTableView).map(selectionChanged) }
}

// MARK: - Flat

extension KeyListDataSource: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        // NSOutlineView is an NSTableView too, but it asks its own data source methods.
        tableView === self.tableView ? keyCount : 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cached = flatRows[row]
        return cell(in: tableView, row: cached?.row, stale: cached?.stamp != stamp)
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { KeyListRowView() }

    public func tableViewSelectionDidChange(_ notification: Notification) { (notification.object as? NSTableView).map(selectionChanged) }
}

// MARK: - Menu

extension KeyListDataSource: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items = menuItems(forRow: activeView.clickedRow)
    }
}

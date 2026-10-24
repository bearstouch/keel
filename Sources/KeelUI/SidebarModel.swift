import AppKit
import Combine
import Foundation
import KeelCore

/// The sidebar of saved connections (FR-CN13, 08 Design → Sidebar): top-level profiles, then one group per folder in
/// the document's order. Rows are one line; host and port live in the tooltip. Every change goes through
/// `ProfileStore`, so order, folders and collapse state persist in `connections.json` and survive relaunch; a refused
/// change leaves the previous state on screen and says why in `message`.
@MainActor
public final class SidebarModel: ObservableObject {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var label: LabelColor
        public var labelName: String
        public var status: ConnectionStatus
        /// `host:port`, plus the tunnel; never the password or username.
        public var tooltip: String

        /// "payments-prod, Production, connected" (FR-CN13): name, label and status, in words.
        public var accessibilityLabel: String { SidebarModel.accessibilityLabel(name: name, labelName: label == .none ? nil : labelName, status: status) }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        /// nil: the top level, which has no heading.
        public let folderID: UUID?
        public var name: String?
        public var collapsed: Bool
        public var rows: [Row]

        public var id: String { folderID?.uuidString ?? "top" }
    }

    @Published public private(set) var document = ConnectionsDocument()
    @Published public var selectedProfileID: UUID?
    /// The last refused change, in one line; the view shows it until dismissed.
    @Published public var message: String?

    public let tabs: ConnectionTabs
    private let store: ProfileStore
    private let sheets: ConnectionSheetPresenter?
    private let copy: @MainActor (String) -> Void
    private var watching: Task<Void, Never>?
    private var tabChanges: AnyCancellable?

    public init(
        store: ProfileStore, tabs: ConnectionTabs, sheets: ConnectionSheetPresenter? = nil,
        copy: @escaping @MainActor (String) -> Void = {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string)
        }
    ) {
        self.store = store; self.tabs = tabs; self.sheets = sheets; self.copy = copy
        // Statuses come from the tabs, so a tab connecting or failing redraws the row.
        tabChanges = tabs.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit { watching?.cancel() }

    /// Follows the store from now on, so profiles saved by the sheet or an import appear without a reload.
    public func start() {
        guard watching == nil else { return }
        let store = store
        watching = Task { [weak self] in
            for await document in await store.changes() {
                guard let self else { return }
                // `reload()` may already show a newer document than this buffered one; never step back.
                if document.revision >= self.document.revision { self.document = document }
            }
        }
    }

    /// Reads the store's current document; actions call it so the view never waits on the change stream.
    public func reload() async { document = await store.document }

    // MARK: Display

    public var groups: [Group] {
        let top = Group(folderID: nil, name: nil, collapsed: false, rows: rows(in: nil))
        let folders = document.folders.map { Group(folderID: $0.id, name: $0.name, collapsed: $0.collapsed, rows: rows(in: $0.id)) }
        return (top.rows.isEmpty ? [] : [top]) + folders
    }

    /// The rows Return and the arrow keys walk: those not hidden in a collapsed folder.
    public var visibleRows: [Row] { groups.filter { !$0.collapsed }.flatMap(\.rows) }

    private func rows(in folderID: UUID?) -> [Row] {
        document.profiles.filter { $0.folderID == folderID }.map { profile in
            let settings = profile.settings
            return Row(
                id: profile.id, name: settings.name, label: settings.label, labelName: document.label(settings.label).name,
                status: tabs.status(ofProfile: profile.id), tooltip: Self.tooltip(settings))
        }
    }

    static func tooltip(_ settings: ConnectionSettings) -> String {
        let host = settings.host.contains(":") && !settings.host.hasPrefix("[") ? "[\(settings.host)]" : settings.host
        let address = "\(host):\(settings.port)"
        switch settings.tunnel {
        case nil: return address
        case .savedHost: return address + " via SSH"
        case .inline(let destination, _, _, _): return address + " via " + destination
        }
    }

    public nonisolated static func accessibilityLabel(name: String, labelName: String?, status: ConnectionStatus) -> String {
        [name, labelName ?? "no label", status.spoken].joined(separator: ", ")
    }

    // MARK: Opening

    /// Double-click or Return: focuses the tab already showing this profile on its database, else opens one; `newTab`
    /// (⌥) always opens another (FR-AP01).
    public func open(_ profileID: UUID, newTab: Bool = false) {
        guard let profile = profile(profileID) else { return }
        selectedProfileID = profileID
        tabs.open(profileID: profileID, database: profile.settings.database, newTab: newTab)
    }

    /// Return opens only a row the user can see: a selection moved into, or collapsed elsewhere into, a hidden folder
    /// opens nothing.
    public func openSelection(newTab: Bool = false) {
        guard let selectedProfileID, visibleRows.contains(where: { $0.id == selectedProfileID }) else { return }
        open(selectedProfileID, newTab: newTab)
    }

    /// Moves the selection by `offset` visible rows; with nothing selected, Down picks the first row and Up the last.
    public func moveSelection(by offset: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == selectedProfileID }) else {
            selectedProfileID = (offset < 0 ? rows.last : rows.first)?.id
            return
        }
        selectedProfileID = rows[min(max(current + offset, 0), rows.count - 1)].id
    }

    // MARK: Profiles

    public func newConnection(inFolder folderID: UUID? = nil) { sheets?.newConnection(folderID: folderID) }
    public func edit(_ profileID: UUID) { sheets?.edit(profileID) }

    /// Copies `redis[s]://user@host:port/db`; the password never leaves the Keychain (INT-04).
    public func copyURL(_ profileID: UUID) {
        guard let profile = profile(profileID) else { return }
        copy(RedisURL(settings: profile.settings).string)
    }

    public func duplicate(_ profileID: UUID) async {
        if let copy = await perform({ [store] () throws(ProfileStoreError) in try await store.duplicate(profileID) }) { selectedProfileID = copy.id }
    }

    /// Renaming keeps the connection, so the saved password stays (ProfileStore.update).
    public func rename(_ profileID: UUID, to name: String) async {
        guard let profile = profile(profileID) else { return }
        var settings = profile.settings
        settings.name = name.trimmingCharacters(in: .whitespaces)
        await perform { [store] () throws(ProfileStoreError) in _ = try await store.update(profileID, settings, expectedRevision: profile.revision) }
    }

    /// Deletes the profile and its Keychain items, after the view's confirmation, and closes its tabs.
    public func delete(_ profileID: UUID) async {
        guard let profile = profile(profileID) else { return }
        guard await perform({ [store] () throws(ProfileStoreError) in try await store.delete(profileID, expectedRevision: profile.revision) }) != nil else { return }
        tabs.closeAll(profileID: profileID)
        if selectedProfileID == profileID { selectedProfileID = nil }
    }

    /// Moves a profile into `folderID` (nil: top level) just before `beforeID`, or to the end of that group. Dropping
    /// a profile where it already is writes nothing.
    public func move(_ profileID: UUID, toFolder folderID: UUID?, before beforeID: UUID? = nil) async {
        guard beforeID != profileID, let profile = profile(profileID) else { return }
        // The store counts positions among the target group's profiles without the one being moved.
        let group = document.profiles.filter { $0.folderID == folderID && $0.id != profileID }.map(\.id)
        let position = beforeID.flatMap { group.firstIndex(of: $0) } ?? group.count
        let current = document.profiles.filter { $0.folderID == folderID }.map(\.id)
        guard profile.folderID != folderID || current.firstIndex(of: profileID) != position else { return }
        await perform { [store] () throws(ProfileStoreError) in
            _ = try await store.move(profileID, toFolder: folderID, position: position, expectedRevision: profile.revision)
        }
    }

    // MARK: Folders

    public func toggleCollapsed(_ folderID: UUID) async {
        guard let folder = folder(folderID) else { return }
        await setCollapsed(folderID, !folder.collapsed)
    }

    public func setCollapsed(_ folderID: UUID, _ collapsed: Bool) async {
        // A collapsed folder hides the selection, so Return can't open a row the user can't see.
        if collapsed, let selected = selectedProfileID, profile(selected)?.folderID == folderID { selectedProfileID = nil }
        await perform { [store] () throws(ProfileStoreError) in _ = try await store.setFolderCollapsed(folderID, collapsed) }
    }

    public func createFolder(named name: String) async {
        await perform { [store] () throws(ProfileStoreError) in _ = try await store.createFolder(named: name.trimmingCharacters(in: .whitespaces)) }
    }

    public func renameFolder(_ folderID: UUID, to name: String) async {
        guard let folder = folder(folderID) else { return }
        await perform { [store] () throws(ProfileStoreError) in
            _ = try await store.renameFolder(folderID, to: name.trimmingCharacters(in: .whitespaces), expectedRevision: folder.revision)
        }
    }

    /// Removes the folder; its profiles move to the top level and nothing else is deleted.
    public func deleteFolder(_ folderID: UUID) async {
        guard let folder = folder(folderID) else { return }
        await perform { [store] () throws(ProfileStoreError) in try await store.deleteFolder(folderID, expectedRevision: folder.revision) }
    }

    /// Moves a folder just before `beforeID`, or to the end.
    public func moveFolder(_ folderID: UUID, before beforeID: UUID?) async {
        guard beforeID != folderID, let current = document.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let others = document.folders.map(\.id).filter { $0 != folderID }
        let position = beforeID.flatMap { others.firstIndex(of: $0) } ?? others.count
        guard position != current else { return }
        await perform { [store] () throws(ProfileStoreError) in try await store.moveFolder(folderID, to: position) }
    }

    // MARK: Drag and drop

    /// What a dragged row or heading carries: an opaque id, nothing about the server.
    public enum DragItem: Equatable, Sendable {
        case profile(UUID), folder(UUID)

        private static let profilePrefix = "keel-profile:", folderPrefix = "keel-folder:"

        public var payload: String {
            switch self {
            case .profile(let id): Self.profilePrefix + id.uuidString
            case .folder(let id): Self.folderPrefix + id.uuidString
            }
        }

        /// Text dropped from elsewhere parses to nil and is ignored.
        public init?(payload: String) {
            if payload.hasPrefix(Self.profilePrefix), let id = UUID(uuidString: String(payload.dropFirst(Self.profilePrefix.count))) {
                self = .profile(id)
            } else if payload.hasPrefix(Self.folderPrefix), let id = UUID(uuidString: String(payload.dropFirst(Self.folderPrefix.count))) {
                self = .folder(id)
            } else {
                return nil
            }
        }
    }

    /// A drop on a row (`beforeProfile`) or a group's heading or end (`folderID`). Profiles land before the row or at
    /// the end of the group; folders reorder among folders. Returns whether the drop was understood.
    @discardableResult
    public func drop(_ payloads: [String], into folderID: UUID?, beforeProfile: UUID? = nil) async -> Bool {
        guard let item = payloads.lazy.compactMap(DragItem.init(payload:)).first else { return false }
        switch item {
        case .profile(let id):
            guard document.profiles.contains(where: { $0.id == id }) else { return false }
            await move(id, toFolder: folderID, before: beforeProfile)
        case .folder(let id):
            // A folder dropped on a heading goes before that folder; folders never nest (FR-CN13).
            guard document.folders.contains(where: { $0.id == id }) else { return false }
            await moveFolder(id, before: folderID)
        }
        return true
    }

    // MARK: Internals

    /// A tab's title: its profile's name ("Deleted connection" for a tab outliving its profile until it closes).
    public func profileName(_ id: UUID) -> String { profile(id)?.settings.name ?? "Deleted connection" }

    public func profileLabel(_ id: UUID) -> LabelColor { profile(id)?.settings.label ?? .none }

    /// Whether the profile's label is treated as production (FR-SF02); a deleted profile isn't.
    public func isProduction(_ id: UUID) -> Bool { profile(id).map { document.label($0.settings.label).treatAsProduction } ?? false }

    /// The production strip over the selected tab (FR-SF02): nil unless that tab is production. "Read-only" follows what
    /// the connected session enforces (or the server refuses); a tab that isn't connected shows the profile's flag.
    public var productionStrip: String? {
        guard let tab = tabs.selected, isProduction(tab.profileID) else { return nil }
        let session = tabs.app?.session(tab.id)
        let readOnly = session?.writesBlocked ?? profile(tab.profileID)?.settings.readOnly ?? true
        return ProductionChrome.stripText(readOnly: readOnly || session?.serverReadOnly == true)
    }

    /// The native window's title, which the Window menu lists: the selected tab's connection, "[PROD]" for production.
    public var windowTitle: String {
        guard let tab = tabs.selected else { return ProductionChrome.windowTitle(name: nil, production: false) }
        return ProductionChrome.windowTitle(name: profileName(tab.profileID), production: isProduction(tab.profileID))
    }

    private func profile(_ id: UUID) -> ConnectionProfile? { document.profiles.first { $0.id == id } }
    private func folder(_ id: UUID) -> ProfileFolder? { document.folders.first { $0.id == id } }

    /// Runs one store change, then shows the store's document. A refusal keeps the previous state and sets `message`.
    @discardableResult
    private func perform<T>(_ change: () async throws(ProfileStoreError) -> T) async -> T? {
        let result: T?
        do throws(ProfileStoreError) { result = try await change() } catch {
            message = error.sidebarMessage; result = nil
        }
        await reload()
        return result
    }
}

extension ProfileStoreError {
    /// One line for the sidebar's alert.
    var sidebarMessage: String {
        switch self {
        case .invalid(.folder): "Enter a folder name without control characters, or choose a folder that still exists."
        case .invalid(.name): "Enter a name without control characters."
        case .conflict: "This connection changed elsewhere; try again."
        default: sheetMessage
        }
    }
}

import AppKit
import Combine
import KeelCore
import SwiftUI

/// A palette row and what choosing it does.
public struct PaletteEntry {
    public let item: PaletteItem
    public let run: @MainActor () -> Void

    public init(_ item: PaletteItem, run: @escaping @MainActor () -> Void) { self.item = item; self.run = run }
}

/// One window's command palette (FR-AP03, ⌘K): fuzzy search over what `sources` lists when it opens. The rows are a
/// snapshot taken on presenting, so a list that changes while typing never moves the selection under the cursor.
@MainActor
public final class CommandPaletteModel: ObservableObject {
    @Published public private(set) var isPresented = false
    @Published public var query = "" { didSet { if query != oldValue { update() } } }
    @Published public private(set) var results: [PaletteItem] = []
    @Published public var selectedID: PaletteItem.ID?

    private let sources: @MainActor () -> [PaletteEntry]
    private var entries: [PaletteItem.ID: PaletteEntry] = [:]
    private var items: [PaletteItem] = []

    public init(sources: @escaping @MainActor () -> [PaletteEntry]) { self.sources = sources }

    /// ⌘K: opens with an empty query, or closes when already open.
    public func toggle() { if isPresented { dismiss() } else { present() } }

    public func present() {
        entries = [:]; items = []
        // The first entry wins a duplicate ID (the sources never repeat one; this keeps a mistake harmless).
        for entry in sources() where entries[entry.item.id] == nil {
            entries[entry.item.id] = entry; items.append(entry.item)
        }
        query = ""
        update()
        isPresented = true
    }

    /// Esc, a click outside, or after running a row. The snapshot goes too: it may hold closures over closed tabs.
    public func dismiss() {
        isPresented = false
        entries = [:]; items = []; results = []; selectedID = nil
    }

    /// ↑ / ↓ move the highlighted row, stopping at the ends.
    public func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? -1
        selectedID = results[min(max(current + offset, 0), results.count - 1)].id
    }

    /// Return (or a click): the palette closes first, so the command runs against the window rather than the palette's
    /// field (⌘F's filter takes focus, a sheet attaches to the window).
    public func run(_ id: PaletteItem.ID? = nil) {
        guard let id = id ?? selectedID, let entry = entries[id] else { return }
        dismiss()
        DispatchQueue.main.async { entry.run() }
    }

    private func update() {
        results = PaletteSearch.rank(items, query: query)
        selectedID = results.first?.id
    }
}

/// The palette's rows for one window, in the order shown with no query: open tabs, recent keys, the selected tab's
/// databases, connections, then commands and settings (FR-AP03).
@MainActor
public enum PaletteSources {
    public static func entries(
        window: ConnectionTabs, sidebar: SidebarModel, commands: [PaletteEntry] = [], settings: [PaletteEntry] = []
    ) -> [PaletteEntry] {
        var result: [PaletteEntry] = []
        let app = window.app
        // Open tabs in every window; the palette's own window first.
        let windows = app.map { all in [window] + all.windows.filter { $0 !== window } } ?? [window]
        for tabs in windows {
            for tab in tabs.tabs {
                let item = PaletteItem(
                    id: "tab:\(tab.id)", kind: .tab, title: sidebar.profileName(tab.profileID), subtitle: "db\(tab.database) · \(tab.mode.title)")
                result.append(
                    PaletteEntry(item) { [weak app, weak tabs] in
                        // Without an app model (tests, a window torn down) the tab is selected in place.
                        if let app { app.focus(tabID: tab.id) } else { tabs?.selectedID = tab.id }
                    })
            }
        }
        if let app {
            for (offset, recent) in app.recentKeys.entries.enumerated() where sidebar.profile(recent.profileID) != nil {
                let item = PaletteItem(
                    id: "key:\(offset)", kind: .recentKey, title: KeyDisplay.name(recent.key), subtitle: "\(sidebar.profileName(recent.profileID)) · db\(recent.database)")
                result.append(PaletteEntry(item) { [weak app, weak window] in if let window { app?.open(recent, in: window) } })
            }
        }
        // The selected tab's databases, while its browser is up (the picker's list, counts included).
        if let tab = window.selected, let browser = app?.session(tab.id)?.browser {
            for entry in browser.databases.entries where entry.index != browser.database {
                let item = PaletteItem(id: "db:\(entry.index)", kind: .database, title: entry.name, subtitle: entry.title == entry.name ? "" : entry.title)
                result.append(
                    PaletteEntry(item) { [weak window, weak browser] in
                        window?.setMode(.browser)
                        if let browser { Task { await browser.selectDatabase(entry.index) } }
                    })
            }
        }
        let folders = Dictionary(uniqueKeysWithValues: sidebar.document.folders.map { ($0.id, $0.name) })
        for profile in sidebar.document.profiles {
            let subtitle = [profile.folderID.flatMap { folders[$0] }, SidebarModel.tooltip(profile.settings)].compactMap { $0 }.joined(separator: " · ")
            let item = PaletteItem(id: "connection:\(profile.id)", kind: .connection, title: profile.settings.name, subtitle: subtitle)
            result.append(PaletteEntry(item) { [weak sidebar] in sidebar?.open(profile.id) })
        }
        return result + commands + settings
    }
}

// MARK: - View

/// The palette over the window's content: a 560 px card under the toolbar with the search field and up to eight rows.
/// ↑ / ↓ move, Return runs, Esc or a click outside closes.
struct CommandPaletteOverlay: View {
    @ObservedObject var model: CommandPaletteModel

    var body: some View {
        if model.isPresented {
            ZStack(alignment: .top) {
                // A click outside closes; the window stays readable behind it.
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { model.dismiss() }
                    .accessibilityHidden(true)
                CommandPaletteCard(model: model).padding(.top, 64)
            }
        }
    }
}

private struct CommandPaletteCard: View {
    @ObservedObject var model: CommandPaletteModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.muted).accessibilityHidden(true)
                TextField("Search commands, connections, tabs and keys", text: $model.query)
                    .textFieldStyle(.plain).font(Tokens.interface(15)).foregroundStyle(Tokens.fg)
                    .focused($focused)
                    .onSubmit { model.run() }
                    .onKeyPress(.upArrow) {
                        model.moveSelection(by: -1); return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.moveSelection(by: 1); return .handled
                    }
                    .onExitCommand { model.dismiss() }
                    .accessibilityLabel("Command palette")
                    .accessibilityHint("Type to search, arrow keys to choose, Return to run")
            }
            .padding(.horizontal, 14).frame(height: 44)
            if !model.results.isEmpty {
                Tokens.hair.frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.results) { item in
                                PaletteRow(item: item, selected: item.id == model.selectedID).id(item.id)
                                    .onTapGesture { model.run(item.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 8 * PaletteRow.height + 8)
                    .onChange(of: model.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            } else if !model.query.isEmpty {
                Tokens.hair.frame(height: 1)
                Text("No matches").font(Tokens.interface(13)).foregroundStyle(Tokens.muted).frame(height: PaletteRow.height)
            }
        }
        .frame(width: 560)
        .background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.hair))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct PaletteRow: View {
    static let height: CGFloat = 36
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Key names are data: mono, as everywhere else (DS-02).
            Text(item.title).font(item.kind == .recentKey ? Tokens.mono(13) : Tokens.interface(13)).foregroundStyle(Tokens.fg).lineLimit(1)
            if !item.subtitle.isEmpty { Text(item.subtitle).font(Tokens.interface(12)).foregroundStyle(Tokens.muted).lineLimit(1) }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut { Text(shortcut).font(Tokens.interface(12)).foregroundStyle(Tokens.muted) }
            Text(item.kind.label).font(Tokens.interface(11)).foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, 14).frame(height: Self.height)
        .background(selected ? Tokens.selection : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.kind.label, item.title, item.subtitle, item.shortcut ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

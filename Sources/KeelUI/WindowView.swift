import KeelCore
import SwiftUI

/// What a tab drag carries between tab bars: the tab's ID, prefixed so a sidebar drag never reads as a tab.
public enum TabDragItem {
    static let prefix = "keel-tab:"

    public static func payload(_ tabID: UUID) -> String { prefix + tabID.uuidString }

    public static func tabID(payload: String) -> UUID? {
        payload.hasPrefix(prefix) ? UUID(uuidString: String(payload.dropFirst(prefix.count))) : nil
    }
}

/// The window's right side (board `Main`): the toolbar, the tab bar and the selected tab's content.
struct WindowContent: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tabs: ConnectionTabs

    var body: some View {
        VStack(spacing: 0) {
            ConnectionToolbar(sidebar: sidebar, tabs: tabs)
            TabBar(sidebar: sidebar, tabs: tabs)
            if let strip = sidebar.productionStrip { ProductionStrip(text: strip) }
            if let tab = tabs.selected {
                if let session = tabs.app?.session(tab.id) {
                    // Resolved when clicked: the tab may have moved to another window since Info mode opened.
                    TabContent(tab: tab, session: session, profileName: sidebar.profileName(tab.profileID), browse: { [weak app = tabs.app, id = tab.id] _ in app?.window(containing: id)?.setMode(.browser) }) {
                        tabs.app?.connectIfNeeded(tab.id)
                    }
                } else {
                    Disconnected(name: sidebar.profileName(tab.profileID), failure: nil, connect: nil)
                }
            }
        }
        .background(Tokens.bg)
    }
}

// MARK: - Toolbar

/// 52 px: connection name, db picker, the centered Browser | Console | Info switch and the search icon.
struct ConnectionToolbar: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tabs: ConnectionTabs
    @Environment(\.commandPalette) private var palette

    var body: some View {
        HStack(spacing: 16) {
            if let tab = tabs.selected {
                Text(sidebar.profileName(tab.profileID)).font(Tokens.interface(14, weight: .semibold)).foregroundStyle(Tokens.fg).lineLimit(1)
                if let session = tabs.app?.session(tab.id) {
                    if tab.mode == .browser { ToolbarDatabase(session: session) }
                    if tab.mode == .info { ToolbarServerVersion(session: session) }
                    ServerReadOnlyBadge(session: session)
                }
            }
            Spacer(minLength: 0)
            ModeSwitch(mode: tabs.selected?.mode) { tabs.setMode($0) }
            Spacer(minLength: 0)
            if let tab = tabs.selected, tab.mode == .info, let session = tabs.app?.session(tab.id) {
                // The `Info` board puts the refresh button where the other modes have search.
                ToolbarInfoRefresh(session: session)
            } else {
                // The search icon opens the command palette (⌘K, FR-AP03).
                Button {
                    palette?.toggle()
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Tokens.muted).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(palette == nil)
                .help("Command Palette")
                .accessibilityLabel("Search, command palette")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Tokens.hair.frame(height: 1) }
    }
}

/// The db picker, once the tab's browser exists.
private struct ToolbarDatabase: View {
    @ObservedObject var session: TabSession

    var body: some View {
        if let browser = session.browser { DatabasePicker(model: browser) }
    }
}

/// FR-SI02: "Redis 7.4.1" beside the connection name in Info mode.
private struct ToolbarServerVersion: View {
    @ObservedObject var session: TabSession

    var body: some View {
        if let server = session.server { Text(server.displayName).font(Tokens.interface(12)).foregroundStyle(Tokens.muted).lineLimit(1) }
    }
}

/// Info's refresh button, once the tab's Info mode exists; a fixed-size placeholder keeps the switch centered until then.
private struct ToolbarInfoRefresh: View {
    @ObservedObject var session: TabSession

    var body: some View {
        if let info = session.info { InfoRefreshButton(model: info) } else { Color.clear.frame(width: 30, height: 30) }
    }
}

/// "Server-enforced read-only" with a lock, once the server refused a write for lack of permission (or as a replica).
private struct ServerReadOnlyBadge: View {
    @ObservedObject var session: TabSession

    var body: some View {
        if session.serverReadOnly {
            Label(ProductionChrome.serverReadOnly, systemImage: "lock").font(Tokens.interface(12)).foregroundStyle(Tokens.muted).lineLimit(1)
                .help("The server refused a write: this user or server can't write.")
        }
    }
}

// MARK: - Production

/// 28 px under the tab bar for production tabs (FR-SF02, DS-03): centered text on the maroon `prodStrip`.
struct ProductionStrip: View {
    let text: String

    var body: some View {
        Text(text).font(Tokens.interface(12, weight: .semibold)).foregroundStyle(Tokens.onProdStrip).lineLimit(1)
            .frame(maxWidth: .infinity).frame(height: ProductionChrome.stripHeight)
            .background(Tokens.prodStrip)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// FR-SF07: the first write in a production tab that isn't read-only shows this non-blocking line until dismissed.
struct ProductionWriteNotice: View {
    @ObservedObject var session: TabSession

    var body: some View {
        if session.showsProductionWriteNotice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.warning).accessibilityHidden(true)
                Text(ProductionChrome.writeNotice).font(Tokens.interface(12.5, weight: .semibold)).foregroundStyle(Tokens.fg)
                Text("Changes here reach the production server.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    session.dismissProductionWriteNotice()
                } label: {
                    Text("×").font(Tokens.interface(14)).foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 16).frame(height: 34)
            .background(Tokens.soft)
            .overlay(alignment: .bottom) { Tokens.hair.frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ProductionChrome.writeNotice)
        }
    }
}

/// The mode segments on a `soft` track; the selected one is `segOn` at 600. Disabled without a tab.
struct ModeSwitch: View {
    let mode: TabMode?
    let select: (TabMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TabMode.allCases, id: \.self) { item in
                let selected = item == mode
                Button {
                    select(item)
                } label: {
                    Text(item.title).font(Tokens.interface(12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Tokens.fg : Tokens.muted)
                        .padding(.horizontal, 14).frame(height: 26)
                        .background(selected ? Tokens.segOn : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: selected ? Tokens.segShadow : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help("\(item.title) (⌘\(item.keyEquivalent))")
            }
        }
        .padding(2)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 8))
        .disabled(mode == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }
}

// MARK: - Tab bar

/// 38 px on `tabBar`: one 31 px tab per connection (label dot, name, ×), then +. The active tab is `bg` with a hairline
/// border and joins the content. Tabs drag within and between windows; a tab with unsaved edits asks before closing.
struct TabBar: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tabs: ConnectionTabs

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { offset, tab in
                TabItem(tab: tab, selected: tab.id == tabs.selectedID, name: sidebar.profileName(tab.profileID), label: sidebar.profileLabel(tab.profileID), tabs: tabs)
                    .dropDestination(for: String.self) { items, _ in drop(items, at: offset) }
            }
            newTabButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 38, alignment: .bottom)
        .background(Tokens.tabBar)
        .overlay(alignment: .bottom) { Tokens.hair.frame(height: 1) }
        // Dropped past the last tab: it goes at the end.
        .dropDestination(for: String.self) { items, _ in drop(items, at: nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open connections")
        .alert(closeTitle, isPresented: confirmingClose, presenting: tabs.confirmingCloseTabID) { id in
            Button("Close Tab", role: .destructive) { tabs.app?.requestClose(id, discardingEdits: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its unsaved changes will be lost.")
        }
    }

    private var closeTitle: String {
        let name = tabs.confirmingCloseTabID.flatMap { id in tabs.tabs.first { $0.id == id } }.map { sidebar.profileName($0.profileID) } ?? "this tab"
        return "Close “\(name)”?"
    }

    private var confirmingClose: Binding<Bool> {
        Binding(get: { tabs.confirmingCloseTabID != nil }, set: { if !$0 { tabs.confirmingCloseTabID = nil } })
    }

    /// A tab from this or another window lands at `index` (nil: the end).
    private func drop(_ items: [String], at index: Int?) -> Bool {
        guard let app = tabs.app, let id = items.lazy.compactMap(TabDragItem.tabID(payload:)).first else { return false }
        app.moveTab(id, to: tabs, at: index)
        return true
    }

    /// + (⌘T): the connection picker.
    private var newTabButton: some View {
        Button {
            tabs.showsConnectionPicker = true
        } label: {
            Text("+").font(Tokens.interface(16)).foregroundStyle(Tokens.muted).frame(width: 30, height: 31)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New tab")
        .help("New Tab (⌘T)")
        .popover(isPresented: $tabs.showsConnectionPicker, arrowEdge: .bottom) { ConnectionPicker(sidebar: sidebar, tabs: tabs) }
    }
}

/// One tab: label dot, name, ×; a context menu for the connection and moving the tab.
private struct TabItem: View {
    let tab: ConnectionTab
    let selected: Bool
    let name: String
    let label: LabelColor
    @ObservedObject var tabs: ConnectionTabs

    var body: some View {
        HStack(spacing: 8) {
            if let color = Tokens.label(label) {
                Circle().fill(color).frame(width: 7, height: 7)
            } else {
                Circle().strokeBorder(Tokens.muted, lineWidth: 1).frame(width: 7, height: 7)
            }
            Text(name).font(Tokens.interface(12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Button {
                tabs.app?.requestClose(tab.id)
            } label: {
                Text("×").font(Tokens.interface(14)).foregroundStyle(Tokens.muted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .accessibilityLabel("Close tab")
        }
        .foregroundStyle(selected ? Tokens.fg : Tokens.muted)
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 31)
        .background(selected ? Tokens.bg : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay {
            if selected { UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).strokeBorder(Tokens.hair, lineWidth: 1).mask(Rectangle().padding(.bottom, -1)) }
        }
        // The active tab covers the bar's bottom hairline, so it joins the content.
        .padding(.bottom, selected ? -1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { tabs.selectedID = tab.id }
        .draggable(TabDragItem.payload(tab.id)) { Text(name).font(Tokens.interface(12.5)).padding(6) }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(tab.status.spoken)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction { tabs.selectedID = tab.id }
    }

    @ViewBuilder private var menu: some View {
        let app = tabs.app
        if tab.status == .connected || tab.status == .connecting {
            Button("Reconnect") { Task { await app?.reconnect(tab.id) } }
            Button("Disconnect") { Task { await app?.disconnect(tab.id) } }
        } else {
            Button("Connect") { app?.connectIfNeeded(tab.id) }
        }
        Divider()
        Button("Move to New Window") { app?.moveTabToNewWindow(tab.id) }.disabled(tabs.tabs.count < 2)
        Button("Close Tab") { app?.requestClose(tab.id) }
    }
}

/// ⌘T / +: every saved connection; choosing one opens it in a new tab of this window.
private struct ConnectionPicker: View {
    @ObservedObject var sidebar: SidebarModel
    let tabs: ConnectionTabs

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New Tab").font(Tokens.interface(12, weight: .semibold)).foregroundStyle(Tokens.muted).padding(.horizontal, 8).padding(.bottom, 4)
            if sidebar.document.profiles.isEmpty {
                Text("No connections yet").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sidebar.document.profiles) { profile in
                        Button {
                            tabs.showsConnectionPicker = false
                            sidebar.open(profile.id, newTab: true)
                        } label: {
                            Text(profile.settings.name).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(10)
        .frame(width: 260)
    }
}

// MARK: - Content

/// The selected tab: its browser when connected, otherwise what the connection is doing, with Connect.
struct TabContent: View {
    let tab: ConnectionTab
    @ObservedObject var session: TabSession
    let profileName: String
    /// Browse on an Info database row: the window shows the tab's Browser mode.
    let browse: (Int) -> Void
    let connect: () -> Void

    var body: some View {
        switch session.status {
        case .connected:
            switch tab.mode {
            case .browser:
                if let browser = session.browser { BrowserLayout(browser: browser, session: session) }
            case .console:
                if let console = session.console { ConsolePane(console: console, session: session) } else { Color(nsColor: ConsoleTheme.background).onAppear { session.openConsole() } }
            case .info:
                // One identity per tab: switching between two tabs in Info mode must disappear one model and appear the other.
                Group { if let info = session.info { InfoPane(model: info) } else { Tokens.bg.onAppear { session.openInfo(browse: browse) } } }.id(session.id)
            }
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(profileName)…").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .disconnected, .failed:
            Disconnected(name: profileName, failure: session.failure, connect: connect)
        }
    }
}

/// The key list (380 wide) beside the editor area.
private struct BrowserLayout: View {
    @ObservedObject var browser: BrowserModel
    let session: TabSession

    var body: some View {
        HStack(spacing: 0) {
            BrowserPane(model: browser) { action in
                switch action {
                case .loadMore, .retry: await browser.list.index.loadMore()
                case .continue: await browser.list.index.continueScanning()
                }
            }
            .frame(width: 380)
            Tokens.hair.frame(width: 1)
            VStack(spacing: 0) {
                ProductionWriteNotice(session: session)
                EditorArea(browser: browser).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Tokens.bg)
        }
        .sheet(isPresented: $browser.showsNewKey) { NewKeySheet(browser: browser) }
    }
}

/// "Disconnected · Connect" (FR-CN15), or the failure with its suggestion and Connect to try again.
private struct Disconnected: View {
    let name: String
    let failure: ConnectionFailure?
    let connect: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(name).font(Tokens.interface(14, weight: .semibold)).foregroundStyle(Tokens.fg)
            if let failure {
                Text("Failed").font(Tokens.interface(12.5, weight: .semibold)).foregroundStyle(Tokens.danger)
                Text(failure.message).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg).multilineTextAlignment(.center)
                Text(failure.suggestion).font(Tokens.interface(12)).foregroundStyle(Tokens.muted).multilineTextAlignment(.center)
            }
            HStack(spacing: 4) {
                if failure == nil { Text("Disconnected ·").foregroundStyle(Tokens.muted) }
                if let connect {
                    Button(failure == nil ? "Connect" : "Try Again", action: connect).buttonStyle(.plain).foregroundStyle(Tokens.accent)
                }
            }
            .font(Tokens.interface(12.5))
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

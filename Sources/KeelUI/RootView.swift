import KeelCore
import SwiftUI

/// The window's content: the connections sidebar beside the toolbar, tab bar and selected tab (board `Main`); with no
/// tab, a quiet empty state (FR-AP08's welcome screen replaces it in KEEL-050).
public struct RootView: View {
    /// ssh's prompts for tunnels (FR-CN07); nil in previews and tests.
    let prompts: SSHPromptCenter?
    /// The New Connection sheet (FR-CN19); nil in previews and tests.
    let connections: ConnectionSheetPresenter?
    /// The connections sidebar (FR-CN13); nil in previews and tests.
    let sidebar: SidebarModel?
    /// Import / Export Connections (FR-CN14); nil in previews and tests.
    let transfer: ProfileTransferModel?

    public init(prompts: SSHPromptCenter? = nil, connections: ConnectionSheetPresenter? = nil, sidebar: SidebarModel? = nil, transfer: ProfileTransferModel? = nil) {
        self.prompts = prompts; self.connections = connections; self.sidebar = sidebar; self.transfer = transfer
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let sidebar {
                SidebarView(model: sidebar)
                Detail(sidebar: sidebar, tabs: sidebar.tabs, connections: connections)
            } else {
                EmptyState(hasProfiles: false, connections: connections)
            }
        }
        .background(Tokens.bg)
        .connectionSheet(connections)
        .profileTransfer(transfer)
        .sshPrompts(prompts)
        // Outside the sheets, so they read it: only one window presents the app-wide sheets.
        .modifier(SheetGate(app: sidebar?.tabs.app, windowID: sidebar?.tabs.id))
    }

    public static let accessibilityLabel = "Keel, no connections yet"
}

/// The window's tabs, or the empty state.
private struct Detail: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tabs: ConnectionTabs
    let connections: ConnectionSheetPresenter?

    var body: some View {
        // ⌘T in an empty window shows the tab bar too: its + anchors the connection picker.
        if !tabs.tabs.isEmpty || tabs.showsConnectionPicker {
            WindowContent(sidebar: sidebar, tabs: tabs)
        } else {
            EmptyState(hasProfiles: !sidebar.document.profiles.isEmpty, connections: connections)
        }
    }
}

private struct EmptyState: View {
    let hasProfiles: Bool
    let connections: ConnectionSheetPresenter?

    var body: some View {
        VStack(spacing: 8) {
            Text("Keel").font(.system(size: 34, weight: .bold))
            if hasProfiles {
                Text("Double-click a connection to open it").foregroundStyle(.secondary)
            } else {
                Text("No connections yet").foregroundStyle(.secondary)
                    .accessibilityLabel(RootView.accessibilityLabel)
                if let connections {
                    Button("New Connection…") { connections.newConnection() }.padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EnvironmentValues {
    /// False in every window but the one chosen to show the app-wide sheets (New Connection, SSH prompts, import),
    /// so a sheet never opens in several windows at once.
    @Entry var presentsSharedSheets = true
}

/// Sets `presentsSharedSheets` for one window from the app's choice (`AppModel.sheetWindowID`). Only the environment
/// changes, never the content's identity, so the window keeps its state when another window becomes the host.
private struct SheetGate: ViewModifier {
    let app: AppModel?
    let windowID: UUID?

    func body(content: Content) -> some View {
        if let app { content.modifier(Observing(app: app, windowID: windowID)) } else { content }
    }

    private struct Observing: ViewModifier {
        @ObservedObject var app: AppModel
        let windowID: UUID?

        func body(content: Content) -> some View { content.environment(\.presentsSharedSheets, app.sheetWindowID == windowID) }
    }
}

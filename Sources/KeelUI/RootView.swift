import KeelCore
import SwiftUI

/// The window's content: the connections sidebar beside the selected tab. Until the browser exists (KEEL-020/026) a
/// tab shows only its connection; with no tab, a quiet empty state (FR-AP08's welcome screen replaces it in KEEL-055).
public struct RootView: View {
    /// ssh's prompts for tunnels (FR-CN07); nil in previews and tests.
    let prompts: SSHPromptCenter?
    /// The New Connection sheet (FR-CN19); nil in previews and tests.
    let connections: ConnectionSheetPresenter?
    /// The connections sidebar (FR-CN13); nil in previews and tests.
    let sidebar: SidebarModel?

    public init(prompts: SSHPromptCenter? = nil, connections: ConnectionSheetPresenter? = nil, sidebar: SidebarModel? = nil) {
        self.prompts = prompts; self.connections = connections; self.sidebar = sidebar
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
        .sshPrompts(prompts)
    }

    public static let accessibilityLabel = "Keel, no connections yet"
}

/// The selected tab's connection, or the empty state.
private struct Detail: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tabs: ConnectionTabs
    let connections: ConnectionSheetPresenter?

    var body: some View {
        if let tab = tabs.selected, let profile = sidebar.document.profiles.first(where: { $0.id == tab.profileID }) {
            VStack(spacing: 6) {
                Text(profile.settings.name).font(Tokens.interface(14, weight: .semibold))
                Text("db\(tab.database) · \(tab.status.spoken)").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
            }
            .foregroundStyle(Tokens.fg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
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

import SwiftUI

/// The window's content until the browser exists: a quiet empty state (FR-AP08's welcome screen replaces it in KEEL-055).
public struct RootView: View {
    /// ssh's prompts for tunnels (FR-CN07); nil in previews and tests.
    let prompts: SSHPromptCenter?
    /// The New Connection sheet (FR-CN19); nil in previews and tests.
    let connections: ConnectionSheetPresenter?

    public init(prompts: SSHPromptCenter? = nil, connections: ConnectionSheetPresenter? = nil) { self.prompts = prompts; self.connections = connections }

    public var body: some View {
        VStack(spacing: 8) {
            Text("Keel").font(.system(size: 34, weight: .bold))
            Text("No connections yet").foregroundStyle(.secondary)
                .accessibilityLabel(RootView.accessibilityLabel)
            if let connections {
                Button("New Connection…") { connections.newConnection() }.padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .connectionSheet(connections)
        .sshPrompts(prompts)
    }

    public static let accessibilityLabel = "Keel, no connections yet"
}

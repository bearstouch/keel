import SwiftUI

/// The window's content until the browser exists: a quiet empty state (FR-AP08's welcome screen replaces it in KEEL-055).
public struct RootView: View {
    /// ssh's prompts for tunnels (FR-CN07); nil in previews and tests.
    let prompts: SSHPromptCenter?

    public init(prompts: SSHPromptCenter? = nil) { self.prompts = prompts }

    public var body: some View {
        VStack(spacing: 8) {
            Text("Keel").font(.system(size: 34, weight: .bold))
            Text("No connections yet").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RootView.accessibilityLabel)
        .sshPrompts(prompts)
    }

    public static let accessibilityLabel = "Keel, no connections yet"
}

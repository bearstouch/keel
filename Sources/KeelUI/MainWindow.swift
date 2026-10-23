import AppKit
import SwiftUI

/// Builds Keel's main native window. It lives in `KeelUI` rather than the app target so its title, size limits and
/// content can be tested without launching the app.
@MainActor
public enum MainWindow {
    public static let title = "Keel"
    public static let minimumSize = NSSize(width: 720, height: 480)

    public static func make(prompts: SSHPromptCenter? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.minSize = minimumSize
        // The app owns the window's lifetime; AppKit must not release it on close behind our back.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(prompts: prompts))
        return window
    }
}

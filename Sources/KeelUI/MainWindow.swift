import AppKit
import SwiftUI

/// Builds Keel's main native window. It lives in `KeelUI` rather than the app target so its title, size limits and
/// content can be tested without launching the app.
@MainActor
public enum MainWindow {
    public static let title = "Keel"
    public nonisolated static let minimumSize = NSSize(width: 720, height: 480)

    public static func make(
        prompts: SSHPromptCenter? = nil, connections: ConnectionSheetPresenter? = nil, sidebar: SidebarModel? = nil, transfer: ProfileTransferModel? = nil,
        palette: CommandPaletteModel? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        // The sidebar runs up under the traffic lights (board `Sidebar`); the title stays for the Window menu and VoiceOver.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = minimumSize
        // The app owns the window's lifetime; AppKit must not release it on close behind our back.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(prompts: prompts, connections: connections, sidebar: sidebar, transfer: transfer, palette: palette))
        return window
    }

    /// A saved frame placed on today's displays (MAC-05): kept when its title bar is on one, shrunk to fit that display
    /// and moved inside it; nil (center instead) when no display shows its title bar any more.
    public nonisolated static func constrained(_ frame: NSRect, to screens: [NSRect]) -> NSRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        // The title bar (top 28 px) is what the user grabs: at least part of it must be on a display.
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        guard let screen = screens.first(where: { $0.intersects(titleBar) }) else { return nil }
        let width = min(max(frame.width, minimumSize.width), screen.width), height = min(max(frame.height, minimumSize.height), screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width), y = min(max(frame.maxY - height, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

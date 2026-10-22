import AppKit
import KeelCore
import KeelUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: LaunchArguments
    private let stateDirectory: URL
    private var window: NSWindow?

    init(arguments: LaunchArguments, stateDirectory: URL) { self.arguments = arguments; self.stateDirectory = stateDirectory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keel's tabs belong to its own model (MAC-05), never to macOS automatic window tabbing.
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenus()
        let window = MainWindow.make()
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "Keel")
        appMenu.addItem(withTitle: "Quit Keel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}

@main
struct KeelMain {
    @MainActor static func main() {
        let arguments: LaunchArguments
        // EX_USAGE (64): a mistyped flag must not start the app against unexpected state.
        do { arguments = try LaunchArguments.parse(CommandLine.arguments.dropFirst()) } catch { fail(error, status: 64) }
        let identity = AppInstanceIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
        let directory = StateLocation.resolve(
            arguments: arguments, identity: identity,
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            temporary: FileManager.default.temporaryDirectory)
        // EX_CANTCREAT (73): without a usable state folder nothing can be saved, so refuse to launch.
        do { try StateLocation.prepare(directory) } catch { fail(error, status: 73) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(arguments: arguments, stateDirectory: directory)
        app.delegate = delegate
        // `NSApplication.delegate` is weak; keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Startup failures go to stderr with a sysexits status so scripts and CI can tell them apart.
    private static func fail(_ error: any Error, status: Int32) -> Never {
        FileHandle.standardError.write(Data("keel: \(error)\n".utf8)); exit(status)
    }
}

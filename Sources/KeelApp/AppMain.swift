import AppKit
import KeelCore
import KeelSSH
import KeelUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let arguments: LaunchArguments
    private let stateDirectory: URL
    private var window: NSWindow?
    /// ssh's prompts other than a saved password, shown in a sheet over the main window (FR-CN07).
    let promptRelay = PromptRelay()
    /// Answers `keel-askpass`; nil when the helper isn't built or bundled. Opens its socket on the first tunnel.
    let askpass: AskpassBroker?
    /// Every SSH tunnel of this run; sessions take it from here. Creates nothing until the first tunnel opens.
    let tunnels: TunnelManager
    private var prompts: SSHPromptCenter?
    /// The single owner of `connections.json` and the profiles' Keychain items.
    let profiles: ProfileStore
    private var connections: ConnectionSheetPresenter?

    init(arguments: LaunchArguments, stateDirectory: URL) {
        self.arguments = arguments; self.stateDirectory = stateDirectory
        let relay = promptRelay
        askpass = Bundle.main.executableURL.flatMap { AskpassHelperLocation.find(executable: $0) }.map { AskpassBroker(helperPath: $0, relay: relay) }
        tunnels = TunnelManager(askpass: askpass)
        profiles = ProfileStore(directory: stateDirectory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keel's tabs belong to its own model (MAC-05), never to macOS automatic window tabbing.
        NSWindow.allowsAutomaticWindowTabbing = false
        // ssh processes a crashed or killed run left behind (NFR-RS05); off the main thread, it only reads small files.
        Task.detached(priority: .utility) { StaleTunnelCleanup().run() }
        buildMenus()
        let prompts = SSHPromptCenter(relay: promptRelay)
        self.prompts = prompts
        Task { await prompts.attach() }
        // A file that needs recovery keeps the store read-only; Save then says so (the recovery choice is KEEL-055's).
        Task { [profiles] in _ = await profiles.load() }
        let connections = ConnectionSheetPresenter(store: profiles, tester: ConnectionTester(tunnels: tunnels))
        self.connections = connections
        let window = MainWindow.make(prompts: prompts, connections: connections)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// No ssh outlives the app (AC3): quitting waits for every tunnel's process group to be terminated (at most ~1 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { [tunnels, askpass] in
            await tunnels.shutdown()
            askpass?.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func newConnection(_ sender: Any?) { connections?.newConnection() }

    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "Keel")
        appMenu.addItem(withTitle: "Quit Keel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Connection…", action: #selector(newConnection(_:)), keyEquivalent: "n").target = self
        fileItem.submenu = fileMenu
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

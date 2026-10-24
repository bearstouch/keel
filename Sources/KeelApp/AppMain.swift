import AppKit
import KeelCore
import KeelSSH
import KeelUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let arguments: LaunchArguments
    private let stateDirectory: URL
    /// ssh's prompts other than a saved password, shown in a sheet over the key window (FR-CN07).
    let promptRelay = PromptRelay()
    /// Answers `keel-askpass`; nil when the helper isn't built or bundled. Opens its socket on the first tunnel.
    let askpass: AskpassBroker?
    /// Every SSH tunnel of this run; sessions take it from here. Creates nothing until the first tunnel opens.
    let tunnels: TunnelManager
    private var prompts: SSHPromptCenter?
    /// The single owner of `connections.json` and the profiles' Keychain items.
    let profiles: ProfileStore
    /// The single owner of `hosts.json` and the `Keel SSH Host` Keychain items (FR-CN06).
    let sshHosts: HostLibrary
    /// The single owner of `known-ca.json` (FR-CN04).
    let knownCA: KnownCAStore
    private var connections: ConnectionSheetPresenter?
    private var transfer: ProfileTransferModel?
    /// Every window's tabs and every tab's session; `windows.json` (FR-AP01).
    private var app: AppModel?
    /// The native window of each of the model's windows.
    private var nativeWindows: [UUID: NSWindow] = [:]
    /// Set on quit: windows closing then are saved as open, not removed.
    private var terminating = false
    /// A window whose close the user confirmed despite unsaved edits.
    private var confirmedClose: Set<UUID> = []

    init(arguments: LaunchArguments, stateDirectory: URL) {
        self.arguments = arguments; self.stateDirectory = stateDirectory
        let relay = promptRelay
        askpass = Bundle.main.executableURL.flatMap { AskpassHelperLocation.find(executable: $0) }.map { AskpassBroker(helperPath: $0, relay: relay) }
        tunnels = TunnelManager(askpass: askpass)
        profiles = ProfileStore(directory: stateDirectory)
        sshHosts = HostLibrary(storage: HostFileStorage(directory: stateDirectory), secrets: KeychainHostSecretStore())
        knownCA = KnownCAStore(directory: stateDirectory)
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
        // An unreadable hosts.json is kept and the library stays read-only; the picker then says so on Save.
        Task { [sshHosts] in _ = await sshHosts.load() }
        let hosts = sshHosts
        let resolveSavedHost: ConnectionTester.ResolveSavedHost = { id in await hosts.hosts.first { $0.id == id } }
        // Touch ID (or the Mac password) is asked for inside the lookup; declining sends ssh's prompt to the person.
        let savedHostPassword: ConnectionTester.SavedHostPassword = { hosts.savedPassword(for: $0, gate: LocalAuthenticationGate()) }
        let tester = ConnectionTester(tunnels: tunnels, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword)
        connections = ConnectionSheetPresenter(store: profiles, tester: tester, hostLibrary: sshHosts)
        transfer = ProfileTransferModel(store: profiles)
        let connector = ProfileSessionConnector(
            profiles: profiles, knownCA: knownCA, tunnels: tunnels, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword,
            confirmCAChange: { change in await MainActor.run { Self.confirm(change) } })
        let app = AppModel(profiles: profiles, connector: connector, persistence: Persistence(directory: stateDirectory))
        app.presentWindow = { [weak self] in self?.show($0, frame: nil) }
        self.app = app
        Task {
            // Tabs restore against the profiles, so they load first. A connections.json that needs recovery keeps the
            // store read-only (KEEL-050 offers the choice); its tabs then have no profile and aren't restored.
            _ = await profiles.load()
            for (window, frame) in await app.restore() { show(window, frame: frame) }
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// No ssh outlives the app (AC3): quitting saves the windows, then waits for every tunnel's process group to be
    /// terminated (at most ~1 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        Task { [tunnels, askpass, app] in
            await app?.flush()
            await tunnels.shutdown()
            askpass?.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Windows

    /// Creates the native window for one of the model's windows, at its saved frame when that is still on a display
    /// (MAC-05), else cascaded from the key window or centered.
    private func show(_ tabs: ConnectionTabs, frame: SavedFrame?) {
        guard nativeWindows[tabs.id] == nil, let profiles = app?.profiles else { return }
        let sidebar = SidebarModel(store: profiles, tabs: tabs, sheets: connections)
        let window = MainWindow.make(prompts: prompts, connections: connections, sidebar: sidebar, transfer: transfer)
        window.identifier = NSUserInterfaceItemIdentifier(tabs.id.uuidString)
        window.delegate = self
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let frame, let placed = MainWindow.constrained(frame.rect, to: screens) {
            window.setFrame(placed, display: false)
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else {
            window.center()
        }
        nativeWindows[tabs.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    private func windowID(_ window: NSWindow?) -> UUID? { window?.identifier.flatMap { UUID(uuidString: $0.rawValue) } }

    /// The key window's tabs, for the menu commands.
    private var keyTabs: ConnectionTabs? { windowID(NSApp.keyWindow).flatMap { app?.window($0) } }

    func windowDidBecomeKey(_ notification: Notification) {
        // The app-wide sheets follow the key window, but never while one is up: it stays where it opened.
        guard let app, NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return }
        app.sheetWindowID = windowID(notification.object as? NSWindow)
    }

    func windowDidMove(_ notification: Notification) { saveFrame(notification) }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame(notification) }

    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = windowID(window) else { return }
        app?.setFrame(SavedFrame(window.frame), for: id)
    }

    /// MAC-06: a window with unsaved edits asks once before closing.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = windowID(sender), let app, !confirmedClose.contains(id) else { return true }
        let unsaved = app.unsavedTabs(in: id)
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "Close this window with unsaved changes?" : "Close this window with unsaved changes in \(unsaved.count) tabs?"
        alert.informativeText = "The unsaved changes will be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Window").hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard response == .alertSecondButtonReturn, let self, let sender else { return }
            self.confirmedClose.insert(id)
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = windowID(notification.object as? NSWindow) else { return }
        nativeWindows[id] = nil; confirmedClose.remove(id)
        // The app-wide sheets move to a window that is still open.
        if app?.sheetWindowID == id { app?.sheetWindowID = nativeWindows.keys.first }
        // Quitting keeps the window in windows.json, and so does closing the last one (the app quits then, and the
        // next launch should look the same); closing any other by hand removes it and ends its tabs' sessions.
        if !terminating, !nativeWindows.isEmpty { app?.closeWindow(id) }
    }

    /// A changed CA file (FR-CN04): the user decides, and not trusting it is the default (Return).
    private static func confirm(_ change: CAChange) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The CA certificate file “\((change.path as NSString).lastPathComponent)” changed."
        alert.informativeText = "Trust it only if you replaced it yourself. Its SHA-256 is now \(change.current)."
        alert.addButton(withTitle: "Don't Connect")
        alert.addButton(withTitle: "Trust New CA")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Commands

    @objc private func newWindow(_ sender: Any?) { if let window = app?.newWindow() { show(window, frame: nil) } }
    @objc private func newTab(_ sender: Any?) { keyTabs?.showsConnectionPicker = true }
    /// ⌘W: the selected tab (asking first when it has unsaved edits); a window without tabs closes.
    @objc private func closeTab(_ sender: Any?) {
        guard let tabs = keyTabs, let selected = tabs.selectedID else { NSApp.keyWindow?.performClose(sender); return }
        app?.requestClose(selected)
    }
    @objc private func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }
    @objc private func setMode(_ sender: NSMenuItem) {
        guard TabMode.allCases.indices.contains(sender.tag) else { return }
        keyTabs?.setMode(TabMode.allCases[sender.tag])
    }
    @objc private func nextTab(_ sender: Any?) { keyTabs?.selectTab(offset: 1) }
    @objc private func previousTab(_ sender: Any?) { keyTabs?.selectTab(offset: -1) }
    @objc private func reconnect(_ sender: Any?) {
        guard let id = keyTabs?.selectedID else { return }
        Task { await app?.reconnect(id) }
    }
    @objc private func disconnect(_ sender: Any?) {
        guard let id = keyTabs?.selectedID else { return }
        Task { await app?.disconnect(id) }
    }
    @objc private func newConnection(_ sender: Any?) { connections?.newConnection() }
    @objc private func importConnections(_ sender: Any?) { Task { await transfer?.beginImport() } }
    @objc private func exportConnections(_ sender: Any?) { Task { await transfer?.exportConnections() } }
    /// ⌘F: the key window's filter field takes focus (FR-KB05).
    @objc private func focusKeyFilter(_ sender: Any?) { NotificationCenter.default.post(name: KeyListCommands.focusFilterNotification, object: NSApp.keyWindow) }
    /// ⌘R: the key window's browser rescans (FR-KB09).
    @objc private func refreshKeys(_ sender: Any?) { NotificationCenter.default.post(name: KeyListCommands.refreshNotification, object: NSApp.keyWindow) }
    /// ⌘S / ⌘Z: the key window's open editor saves or reverts its unsaved changes (03 → Value editors).
    @objc private func saveEdits(_ sender: Any?) { NotificationCenter.default.post(name: EditorCommands.saveNotification, object: NSApp.keyWindow) }
    @objc private func revertEdits(_ sender: Any?) { NotificationCenter.default.post(name: EditorCommands.revertNotification, object: NSApp.keyWindow) }
    /// ⌘E / ⌥⌘E: the key window's open editor shows Rename… or Set TTL… (FR-ED13).
    @objc private func renameKey(_ sender: Any?) { NotificationCenter.default.post(name: EditorCommands.renameNotification, object: NSApp.keyWindow) }
    @objc private func setKeyTTL(_ sender: Any?) { NotificationCenter.default.post(name: EditorCommands.setTTLNotification, object: NSApp.keyWindow) }
    /// ⌥⌘0…⌥⌘9: the key window's browser switches to the item's database (FR-KB08).
    @objc private func selectDatabase(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: KeyListCommands.selectDatabaseNotification, object: NSApp.keyWindow, userInfo: [KeyListCommands.databaseKey: sender.tag])
    }

    /// Tab commands need a selected tab; the mode items show the current mode's checkmark.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = keyTabs?.selected
        switch item.action {
        case #selector(setMode(_:)):
            item.state = tab.flatMap { TabMode.allCases.firstIndex(of: $0.mode) } == item.tag ? .on : .off
            return tab != nil
        case #selector(reconnect(_:)), #selector(disconnect(_:)): return tab != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return (keyTabs?.tabs.count ?? 0) > 1
        case #selector(newTab(_:)): return keyTabs != nil
        // Only while the selected tab's editor shows the save bar, so ⌘Z means nothing else then.
        case #selector(saveEdits(_:)), #selector(revertEdits(_:)):
            return tab.flatMap { app?.session($0.id)?.browser?.editor?.showsSaveBar } ?? false
        case #selector(renameKey(_:)): return tab.flatMap { app?.session($0.id)?.browser?.editor?.canRename } ?? false
        case #selector(setKeyTTL(_:)): return tab.flatMap { app?.session($0.id)?.browser?.editor?.canRunKeyAction } ?? false
        default: return true
        }
    }

    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "Keel")
        appMenu.addItem(withTitle: "Quit Keel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        // FR-AP02 defaults: ⌘N / ⌘T, ⌘W / ⇧⌘W.
        add("New Window", #selector(newWindow(_:)), "n", to: fileMenu)
        add("New Tab", #selector(newTab(_:)), "t", to: fileMenu)
        add("New Connection…", #selector(newConnection(_:)), "", to: fileMenu)
        fileMenu.addItem(.separator())
        add("Close Tab", #selector(closeTab(_:)), "w", to: fileMenu)
        add("Close Window", #selector(closeWindow(_:)), "w", [.command, .shift], to: fileMenu)
        add("Save Changes", #selector(saveEdits(_:)), "s", to: fileMenu)
        add("Revert Changes", #selector(revertEdits(_:)), "z", to: fileMenu)
        fileMenu.addItem(.separator())
        add("Import Connections…", #selector(importConnections(_:)), "", to: fileMenu)
        add("Export Connections…", #selector(exportConnections(_:)), "", to: fileMenu)
        fileItem.submenu = fileMenu
        // The standard text commands, sent to the first responder (the value viewer, the key filter, sheet fields). No
        // Undo/Redo: ⌘Z is Revert Changes (03 → Value editors).
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for (offset, mode) in TabMode.allCases.enumerated() { add(mode.title, #selector(setMode(_:)), mode.keyEquivalent, to: viewMenu).tag = offset }
        viewMenu.addItem(.separator())
        // Sent to the first responder: the key list answers it while focused (FR-KB03); the menu item is dimmed otherwise.
        let toggle = viewMenu.addItem(withTitle: "Toggle Tree / Flat", action: KeyListCommands.toggleMode, keyEquivalent: "t")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        add("Filter Keys", #selector(focusKeyFilter(_:)), "f", to: viewMenu)
        add("Refresh", #selector(refreshKeys(_:)), "r", to: viewMenu)
        let databaseItem = viewMenu.addItem(withTitle: "Database", action: nil, keyEquivalent: "")
        let databaseMenu = NSMenu(title: "Database")
        for database in 0...9 { add("db\(database)", #selector(selectDatabase(_:)), String(database), [.command, .option], to: databaseMenu).tag = database }
        databaseItem.submenu = databaseMenu
        viewItem.submenu = viewMenu
        let keyItem = NSMenuItem(); menu.addItem(keyItem)
        let keyMenu = NSMenu(title: "Key")
        add("Rename Key…", #selector(renameKey(_:)), "e", to: keyMenu)
        add("Set TTL…", #selector(setKeyTTL(_:)), "e", [.command, .option], to: keyMenu)
        keyItem.submenu = keyMenu
        let connectionItem = NSMenuItem(); menu.addItem(connectionItem)
        let connectionMenu = NSMenu(title: "Connection")
        // FR-CN15: ⇧⌘R / ⇧⌘D.
        add("Reconnect", #selector(reconnect(_:)), "r", [.command, .shift], to: connectionMenu)
        add("Disconnect", #selector(disconnect(_:)), "d", [.command, .shift], to: connectionMenu)
        connectionItem.submenu = connectionMenu
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        add("Show Next Tab", #selector(nextTab(_:)), "]", [.command, .shift], to: windowMenu)
        add("Show Previous Tab", #selector(previousTab(_:)), "[", [.command, .shift], to: windowMenu)
        windowItem.submenu = windowMenu
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = self
        return item
    }
}

extension SavedFrame {
    init(_ rect: NSRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }

    var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
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

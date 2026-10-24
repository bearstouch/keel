import AppKit
import Combine
import KeelCore
import KeelRelease
import KeelSSH
import KeelUI
import Sparkle

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
    /// Keeps each window's title (and so its Window menu item) on its selected tab, "[PROD]" included (FR-SF02).
    private var titleUpdates: [UUID: AnyCancellable] = [:]
    /// The shortcuts the menus show (FR-AP02); Settings → Keyboard changes them.
    private let bindings = ShortcutBindings()
    /// The menu item of each rebindable command, re-keyed when a binding changes.
    private var shortcutItems: [KeelShortcut: NSMenuItem] = [:]
    private var bindingChanges: AnyCancellable?
    /// Each window's command palette and sidebar, for ⌘K and ⌃⌘S.
    private var palettes: [UUID: CommandPaletteModel] = [:]
    private var sidebars: [UUID: SidebarModel] = [:]
    private var settingsWindow: NSWindow?
    /// The single owner of `settings.json` (FR-AP09): the applied settings, the theme (FR-AP04) and the Increase Contrast
    /// flag the tokens read.
    let settings: SettingsModel
    /// The Settings window's edits, kept until Apply or Cancel.
    private var settingsDraft: SettingsDraft?
    private var accessibilityObserver: NSObjectProtocol?
    /// Help → Remove Keel Data… confirmed: removed as the last step of quitting, once nothing is left to save (MAC-22).
    private var pendingRemoval: DataRemovalPlan?
    /// Sparkle (FR-AP07): only in a packaged build with a feed, never with `--fixture`. Started once the settings are
    /// read, so the first check already follows the user's choice.
    private var updates: SPUStandardUpdaterController?
    private var updateSettingChanges: AnyCancellable?

    init(arguments: LaunchArguments, stateDirectory: URL) {
        self.arguments = arguments; self.stateDirectory = stateDirectory
        let relay = promptRelay
        askpass = Bundle.main.executableURL.flatMap { AskpassHelperLocation.find(executable: $0) }.map { AskpassBroker(helperPath: $0, relay: relay) }
        tunnels = TunnelManager(askpass: askpass)
        profiles = ProfileStore(directory: stateDirectory)
        sshHosts = HostLibrary(storage: HostFileStorage(directory: stateDirectory), secrets: KeychainHostSecretStore())
        knownCA = KnownCAStore(directory: stateDirectory)
        settings = SettingsModel(persistence: Persistence(directory: stateDirectory))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keel's tabs belong to its own model (MAC-05), never to macOS automatic window tabbing.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Inter and JetBrains Mono for this process only (MAC-19), before any view asks for them.
        BundledFonts.register()
        accessibilityDisplayOptionsChanged()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibilityDisplayOptionsChanged() }
        }
        // ssh processes a crashed or killed run left behind (NFR-RS05); off the main thread, it only reads small files.
        Task.detached(priority: .utility) { StaleTunnelCleanup().run() }
        if !arguments.fixture, UpdatePolicy.isAvailable(info: Bundle.main.infoDictionary, productionBundleIdentifier: AppInstanceIdentity.production) {
            updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            settings.updatesAvailable = true
        }
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
        // Test and connect read the applied settings (Advanced, Console) when they start, so an Apply reaches the next one.
        let snapshot = settings.snapshot
        let tester = ConnectionTester(tunnels: tunnels, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword, advanced: { snapshot.current.advanced })
        connections = ConnectionSheetPresenter(store: profiles, tester: tester, hostLibrary: sshHosts)
        transfer = ProfileTransferModel(store: profiles)
        let connector = ProfileSessionConnector(
            profiles: profiles, knownCA: knownCA, tunnels: tunnels, resolveSavedHost: resolveSavedHost, savedHostPassword: savedHostPassword,
            confirmCAChange: { change in await MainActor.run { Self.confirm(change) } }, settings: { snapshot.current })
        let app = AppModel(profiles: profiles, connector: connector, persistence: Persistence(directory: stateDirectory), settings: snapshot)
        app.presentWindow = { [weak self] in self?.show($0, frame: nil) }
        app.focusWindow = { [weak self] in self?.nativeWindows[$0]?.makeKeyAndOrderFront(nil) }
        self.app = app
        Task { [settings] in
            // The saved theme first, so restored windows open in it rather than switching after they appear.
            await settings.load()
            // Tabs restore against the profiles, so they load first. A connections.json that needs recovery keeps the
            // store read-only (KEEL-050 offers the choice); its tabs then have no profile and aren't restored.
            _ = await profiles.load()
            for (window, frame) in await app.restore(reopens: settings.applied.restoresWindows) { show(window, frame: frame) }
            NSApp.activate()
            startUpdates()
        }
    }

    /// The saved choice goes on the updater before it starts, and every Apply after (Settings → General).
    private func startUpdates() {
        guard let updates else { return }
        let updater = updates.updater
        UpdatePolicy.apply(checksAutomatically: settings.applied.checksForUpdates, to: updater)
        // `$applied` publishes before the change lands, with the new value.
        updateSettingChanges = settings.$applied.map(\.checksForUpdates).removeDuplicates().dropFirst().sink { UpdatePolicy.apply(checksAutomatically: $0, to: updater) }
        updates.startUpdater()
    }

    /// Keel → Check for Updates…: one check now, shown even when nothing is new; installing still asks first.
    @objc private func checkForUpdates(_ sender: Any?) { updates?.checkForUpdates(sender) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// No ssh outlives the app (AC3): quitting saves the windows, then waits for every tunnel's process group to be
    /// terminated (at most ~1 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        Task { [tunnels, askpass, app, settings, pendingRemoval] in
            await app?.flush()
            if pendingRemoval != nil { app?.stopSaving() }
            await settings.flush()
            await tunnels.shutdown()
            askpass?.stop()
            // After the flushes, planned again: a file the last saves created (a first backup) goes too. The allow-list
            // and the refusals are the same as for the confirmation.
            if let pendingRemoval { Self.remove(Self.removalPlan(pendingRemoval.stateDirectory)) }
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
        let palette = CommandPaletteModel { [weak self, weak tabs, weak sidebar] in
            guard let self, let tabs, let sidebar else { return [] }
            return PaletteSources.entries(window: tabs, sidebar: sidebar, commands: self.paletteCommands(), settings: self.paletteSettings())
        }
        palettes[tabs.id] = palette; sidebars[tabs.id] = sidebar
        let window = MainWindow.make(prompts: prompts, connections: connections, sidebar: sidebar, transfer: transfer, palette: palette)
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
        window.title = sidebar.windowTitle
        // `objectWillChange` fires before the change lands, so the title is read on the next turn of the main queue.
        titleUpdates[tabs.id] = sidebar.objectWillChange.receive(on: DispatchQueue.main).sink { [weak window, weak sidebar] _ in
            guard let window, let sidebar, window.title != sidebar.windowTitle else { return }
            window.title = sidebar.windowTitle
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func windowID(_ window: NSWindow?) -> UUID? { window?.identifier.flatMap { UUID(uuidString: $0.rawValue) } }

    /// The key window's ID when it is one of Keel's main windows (not Settings).
    private var keyWindowID: UUID? { windowID(NSApp.keyWindow).flatMap { nativeWindows[$0] != nil ? $0 : nil } }

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
        nativeWindows[id] = nil; confirmedClose.remove(id); titleUpdates[id] = nil; palettes[id] = nil; sidebars[id] = nil
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
    /// ⌘K: the key window's palette opens, or closes when open (FR-AP03).
    @objc private func toggleCommandPalette(_ sender: Any?) { keyWindowID.flatMap { palettes[$0] }?.toggle() }
    /// ⌃⌘S: the key window's sidebar hides or comes back.
    @objc private func toggleSidebar(_ sender: Any?) { keyWindowID.flatMap { sidebars[$0] }?.isHidden.toggle() }
    /// ⌘⌫: the key window's browser deletes its multi-key selection or the open key, each after its confirmation.
    @objc private func deleteKeys(_ sender: Any?) { NotificationCenter.default.post(name: KeyListCommands.deleteNotification, object: NSApp.keyWindow) }
    private func accessibilityDisplayOptionsChanged() {
        settings.accessibilityDisplayOptionsChanged(increasesContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    /// View → Theme → Light / Dark / System (FR-AP04).
    @objc private func setTheme(_ sender: NSMenuItem) {
        guard ThemeChoice.allCases.indices.contains(sender.tag) else { return }
        settings.setTheme(ThemeChoice.allCases[sender.tag])
        // An open Settings draft follows, so its Apply never brings the replaced theme back.
        settingsDraft?.document.theme = settings.theme
    }

    /// Settings… (⌘,): one window, brought back when already open; `pane` (from the palette) is shown first.
    @objc private func showSettings(_ sender: Any?) { showSettings(pane: nil) }

    private func showSettings(pane: SettingsDraft.Pane?) {
        if settingsWindow == nil {
            let draft = SettingsDraft(settings: settings)
            settingsDraft = draft
            settingsWindow = SettingsWindow.make(draft: draft, keyboard: KeyboardSettingsModel(bindings: bindings))
        }
        // A window brought back keeps its unapplied edits; one opened again starts from the applied settings.
        if settingsWindow?.isVisible == false { settingsDraft?.begin() }
        if let pane { settingsDraft?.pane = pane }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
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
    /// ⇧⌘N: the key window's browser shows the new-key sheet (FR-ED14).
    @objc private func newKey(_ sender: Any?) { NotificationCenter.default.post(name: KeyListCommands.newKeyNotification, object: NSApp.keyWindow) }
    /// ⌥⌘K / ⌘.: the key window's console clears, or stops its stream or command (FR-CO07, FR-CO08).
    @objc private func clearConsole(_ sender: Any?) { NotificationCenter.default.post(name: ConsoleCommands.clearNotification, object: NSApp.keyWindow) }
    @objc private func stopConsoleCommand(_ sender: Any?) { NotificationCenter.default.post(name: ConsoleCommands.stopNotification, object: NSApp.keyWindow) }
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
        case #selector(checkForUpdates(_:)): return updates?.updater.canCheckForUpdates ?? false
        // Only while the selected tab's editor shows the save bar, so ⌘Z means nothing else then.
        case #selector(saveEdits(_:)), #selector(revertEdits(_:)):
            return tab.flatMap { app?.session($0.id)?.browser?.editor?.showsSaveBar } ?? false
        case #selector(renameKey(_:)): return tab.flatMap { app?.session($0.id)?.browser?.editor?.canRename } ?? false
        // Browser mode only, on a writable profile (FR-ED14).
        case #selector(newKey(_:)): return tab.flatMap { $0.mode == .browser ? app?.session($0.id)?.browser?.canCreateKey : nil } ?? false
        case #selector(setKeyTTL(_:)): return tab.flatMap { app?.session($0.id)?.browser?.editor?.canRunKeyAction } ?? false
        // Console mode only; Stop while a command or stream runs.
        case #selector(clearConsole(_:)): return tab.flatMap { $0.mode == .console ? app?.session($0.id)?.console : nil } != nil
        case #selector(stopConsoleCommand(_:)): return tab.flatMap { $0.mode == .console ? app?.session($0.id)?.console?.state : nil }.map { $0 != .idle } ?? false
        case #selector(toggleCommandPalette(_:)): return keyWindowID != nil
        case #selector(setTheme(_:)):
            item.state = ThemeChoice.allCases.firstIndex(of: settings.theme) == item.tag ? .on : .off
            return true
        case #selector(toggleSidebar(_:)):
            let sidebar = keyWindowID.flatMap { sidebars[$0] }
            item.title = sidebar?.isHidden == true ? "Show Sidebar" : "Hide Sidebar"
            return sidebar != nil
        // Browser mode only. Never while text is being edited: there ⌘⌫ deletes to the start of the line.
        case #selector(deleteKeys(_:)):
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
            return tab.flatMap { $0.mode == .browser ? app?.session($0.id)?.browser?.canDeleteSelection : nil } ?? false
        default: return true
        }
    }

    /// The menu bar (MAC-04). Rebindable commands take their chords from `bindings` and follow every change; the fixed
    /// ones (Settings, Hide, Quit, Revert, the text commands, Minimize) keep theirs (FR-AP02).
    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title: "Keel")
        // Builds without an updater have no item (FR-AP07).
        if updates != nil {
            add("Check for Updates…", #selector(checkForUpdates(_:)), "", to: appMenu)
            appMenu.addItem(.separator())
        }
        add("Settings…", #selector(showSettings(_:)), ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Keel", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Keel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        add(.newWindow, #selector(newWindow(_:)), to: fileMenu)
        add(.newTab, #selector(newTab(_:)), to: fileMenu)
        add("New Connection…", #selector(newConnection(_:)), "", to: fileMenu)
        fileMenu.addItem(.separator())
        add(.closeTab, #selector(closeTab(_:)), to: fileMenu)
        add(.closeWindow, #selector(closeWindow(_:)), to: fileMenu)
        add(.saveChanges, #selector(saveEdits(_:)), to: fileMenu)
        // Fixed: ⌘Z stands where Undo would be (KeelShortcut.fixed).
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
        add(.commandPalette, #selector(toggleCommandPalette(_:)), to: viewMenu)
        viewMenu.addItem(.separator())
        for (offset, mode) in TabMode.allCases.enumerated() { add(mode.shortcut, #selector(setMode(_:)), to: viewMenu).tag = offset }
        viewMenu.addItem(.separator())
        // Sent to the first responder: the key list answers it while focused (FR-KB03); the menu item is dimmed otherwise.
        add(.toggleTreeFlat, KeyListCommands.toggleMode, toFirstResponder: true, to: viewMenu)
        add(.filterKeys, #selector(focusKeyFilter(_:)), to: viewMenu)
        add(.refresh, #selector(refreshKeys(_:)), to: viewMenu)
        let databaseItem = viewMenu.addItem(withTitle: "Database", action: nil, keyEquivalent: "")
        let databaseMenu = NSMenu(title: "Database")
        for database in 0...9 {
            guard let action = KeelShortcut.database(database) else { continue }
            add(action, #selector(selectDatabase(_:)), to: databaseMenu).tag = database
            shortcutItems[action]?.title = "db\(database)"
        }
        databaseItem.submenu = databaseMenu
        viewMenu.addItem(.separator())
        add(.clearConsole, #selector(clearConsole(_:)), to: viewMenu)
        add(.stopCommand, #selector(stopConsoleCommand(_:)), to: viewMenu)
        viewMenu.addItem(.separator())
        add(.toggleSidebar, #selector(toggleSidebar(_:)), to: viewMenu)
        viewMenu.addItem(.separator())
        // DS-11: applies at once to every window; sessions and loaded keys are untouched.
        let themeItem = viewMenu.addItem(withTitle: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        for (offset, theme) in ThemeChoice.allCases.enumerated() { add(theme.title, #selector(setTheme(_:)), "", to: themeMenu).tag = offset }
        themeItem.submenu = themeMenu
        viewItem.submenu = viewMenu
        let keyItem = NSMenuItem(); menu.addItem(keyItem)
        let keyMenu = NSMenu(title: "Key")
        add(.newKey, #selector(newKey(_:)), to: keyMenu)
        keyMenu.addItem(.separator())
        add(.renameKey, #selector(renameKey(_:)), to: keyMenu)
        add(.setTTL, #selector(setKeyTTL(_:)), to: keyMenu)
        keyMenu.addItem(.separator())
        add(.deleteKeys, #selector(deleteKeys(_:)), to: keyMenu)
        keyItem.submenu = keyMenu
        let connectionItem = NSMenuItem(); menu.addItem(connectionItem)
        let connectionMenu = NSMenu(title: "Connection")
        add(.reconnect, #selector(reconnect(_:)), to: connectionMenu)
        add(.disconnect, #selector(disconnect(_:)), to: connectionMenu)
        connectionItem.submenu = connectionMenu
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        add(.nextTab, #selector(nextTab(_:)), to: windowMenu)
        add(.previousTab, #selector(previousTab(_:)), to: windowMenu)
        windowItem.submenu = windowMenu
        let helpItem = NSMenuItem(); menu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        add("Export Diagnostics…", #selector(exportDiagnostics(_:)), "", to: helpMenu)
        helpMenu.addItem(.separator())
        add("Remove Keel Data…", #selector(removeKeelData(_:)), "", to: helpMenu)
        helpItem.submenu = helpMenu
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        // `$map` publishes before the change lands, with the new value.
        bindingChanges = bindings.$map.dropFirst().sink { [weak self] in self?.applyShortcuts($0) }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = self
        return item
    }

    /// A rebindable command's item, keyed from its current binding; `toFirstResponder` leaves its target to the responder chain.
    @discardableResult
    private func add(_ shortcut: KeelShortcut, _ action: Selector, toFirstResponder: Bool = false, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: shortcut.title, action: action, keyEquivalent: "")
        item.target = toFirstResponder ? nil : self
        shortcutItems[shortcut] = item
        key(item, bindings[shortcut])
        return item
    }

    private func applyShortcuts(_ map: KeelShortcutMap) { for (shortcut, item) in shortcutItems { key(item, map[shortcut]) } }

    /// An unbound command keeps its item, without a key equivalent.
    private func key(_ item: NSMenuItem, _ chord: KeyChord?) {
        let equivalent = chord?.menuKeyEquivalent
        item.keyEquivalent = equivalent?.key ?? ""
        item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
    }

    // MARK: - Diagnostics

    /// Help → Export Diagnostics (FR-AP10): versions, the profile count, server types and recent error codes, written
    /// only where the user chooses. Never hosts, key names, values or secrets.
    @objc private func exportDiagnostics(_ sender: Any?) {
        Task { [profiles] in
            let report = DiagnosticsReport.current(profileCount: await profiles.profiles.count)
            let panel = NSSavePanel()
            panel.title = "Export Diagnostics"; panel.prompt = "Export"
            panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = DiagnosticsReport.fileName; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try report.encoded().write(to: url, options: .atomic) } catch {
                let alert = NSAlert()
                alert.messageText = "The diagnostics couldn't be exported."; alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Data removal

    /// Help → Remove Keel Data… (MAC-22): lists what would go, asks, then quits and removes it on the way out. Only the
    /// state folder's own files, Keel's three Keychain services and its preference keys are in the plan.
    @objc private func removeKeelData(_ sender: Any?) {
        let plan = Self.removalPlan(stateDirectory)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = plan.isEmpty ? "Keel has no data to remove." : "Remove Keel's data and quit?"
        let untouched = "SSH keys, SSH configuration, known-hosts files and Redis servers are not touched. Client certificates you imported stay in your login keychain."
        let shared = plan.keychainItems.isEmpty ? "" : "\n\nKeychain items are shared by every copy of Keel on this Mac."
        alert.informativeText = (plan.summary.map { "• \($0)" } + ["", untouched]).joined(separator: "\n") + shared
        if plan.isEmpty {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        // Cancel first: Return keeps the data.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove and Quit").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        pendingRemoval = plan
        NSApp.terminate(sender)
    }

    private static func removalPlan(_ stateDirectory: URL) -> DataRemovalPlan {
        DataRemovalPlanner.plan(
            stateDirectory: stateDirectory, home: FileManager.default.homeDirectoryForCurrentUser, keychain: SystemKeychainInventory(),
            storedPreferenceKeys: Set(UserDefaults.standard.dictionaryRepresentation().keys))
    }

    /// Runs the confirmed plan; whatever couldn't be removed is listed before the app quits.
    private static func remove(_ plan: DataRemovalPlan) {
        let result = DataRemovalPlanner.execute(plan, keychain: SystemKeychainInventory()) { UserDefaults.standard.removeObject(forKey: $0) }
        guard !result.failures.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some of Keel's data couldn't be removed."
        alert.informativeText = result.failures.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Command palette

    /// The palette's commands: every enabled menu command of the key window, with its menu and current shortcut. The
    /// Database submenu is the palette's database rows instead; the palette's own item and the text commands are left out.
    private func paletteCommands() -> [PaletteEntry] {
        var result: [PaletteEntry] = []
        let chords = Dictionary(uniqueKeysWithValues: shortcutItems.map { (ObjectIdentifier($0.value), $0.key) })
        for top in NSApp.mainMenu?.items ?? [] {
            guard let submenu = top.submenu, submenu.title != "Edit" else { continue }
            for item in submenu.items {
                guard let action = item.action, item.target === self, action != #selector(toggleCommandPalette(_:)), validateMenuItem(item) else { continue }
                let shortcut = chords[ObjectIdentifier(item)].flatMap { bindings[$0]?.description } ?? (item.keyEquivalent.isEmpty ? nil : fixedChord(item))
                let entry = PaletteItem(id: "command:\(submenu.title):\(item.title)", kind: .action, title: item.title, subtitle: submenu.title, shortcut: shortcut)
                result.append(PaletteEntry(entry) { [weak item] in if let item { NSApp.sendAction(action, to: item.target, from: item) } })
            }
        }
        return result
    }

    private func fixedChord(_ item: NSMenuItem) -> String? { KeelShortcut.fixed.first { $0.title == item.title }?.chord.description }

    /// The palette's settings rows: each Settings pane, opened at that pane.
    private func paletteSettings() -> [PaletteEntry] {
        SettingsDraft.Pane.allCases.map { pane in
            let title = pane == .keyboard ? "Keyboard Shortcuts" : "\(pane.title) Settings"
            return PaletteEntry(PaletteItem(id: "settings:\(pane.rawValue)", kind: .settings, title: title, subtitle: "Settings")) { [weak self] in
                self?.showSettings(pane: pane)
            }
        }
    }
}

/// Sparkle's updater takes the update policy directly (FR-AP07).
extension SPUUpdater: UpdaterControlling {}

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

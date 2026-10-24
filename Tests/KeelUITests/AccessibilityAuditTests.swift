import AppKit
import SwiftUI
import KeelAskpass
import XCTest

@testable import KeelCore
@testable import KeelSSH
@testable import KeelUI

/// Every screen of the app, built over in-memory servers, for the accessibility audit (KEEL-045, NFR-AX01, NFR-AX02).
@MainActor
final class AuditScreens {
    private let directory: URL
    private var hosts: [ScreenHost] = []

    init(directory: URL) { self.directory = directory }

    func closeAll() { hosts.forEach { $0.close() }; hosts = [] }

    private func host<Content: View>(_ content: Content, size: CGSize = CGSize(width: 1180, height: 760)) -> ScreenHost {
        let host = ScreenHost(content.font(Tokens.interface(13)), size: size)
        hosts.append(host)
        return host
    }

    // MARK: - Windows

    /// A first launch: no connections.
    func emptyWindow() -> ScreenHost { host(RootView()) }

    /// The main window: sidebar with a folder and three connections (one production, one read-only), two tabs, the
    /// selected tab connected in `mode`.
    func mainWindow(mode: TabMode = .browser) async throws -> (ScreenHost, AppModel) {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let folder = try await store.createFolder(named: "Production")
        let payments = try await store.create(
            ConnectionSettings(name: "payments-prod", label: .red, tls: TLSSettings(skipVerification: true), readOnly: true), folderID: folder.id)
        let staging = try await store.create(ConnectionSettings(name: "api-staging", label: .orange))
        _ = try await store.create(ConnectionSettings(name: "local-dev", label: .green, readOnly: true))
        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        let window = try XCTUnwrap(app.windows.first)
        let sidebar = SidebarModel(store: store, tabs: window, copy: { _ in })
        await sidebar.reload()
        let palette = CommandPaletteModel { [] }
        let tab = window.open(profileID: payments.id, database: 0)
        _ = window.open(profileID: staging.id, database: 0, newTab: true)
        window.selectedID = tab.id
        app.connectIfNeeded(tab.id)
        for _ in 0..<200 where app.session(tab.id)?.status != .connected { try await Task.sleep(for: .milliseconds(5)) }
        window.setMode(mode)
        let screen = host(RootView(sidebar: sidebar, palette: palette))
        screen.settle(0.3)
        return (screen, app)
    }

    // MARK: - Browser

    func keyList() async -> ScreenHost {
        let keyspace = BrowserKeyspace([0: ["user:1", "user:2", "session:a", "health"]])
        let list = keyspace.list(readOnly: false)
        let filter = KeyFilterModel(list: list) { _ in }
        let model = BrowserModel(list: list, filter: filter, database: 0, databaseCount: 16)
        await model.start()
        let screen = host(
            VStack(spacing: 0) {
                DatabasePicker(model: model); BrowserPane(model: model) { _ in }
            }.frame(width: 380, height: 700), size: CGSize(width: 380, height: 700))
        screen.settle(0.3)
        await list.fetchVisibleContent()
        screen.settle()
        return screen
    }

    func newKeySheet() async -> ScreenHost {
        let model = BrowserModel(list: BrowserKeyspace([0: []]).list(readOnly: false), database: 0)
        return host(NewKeySheet(browser: model), size: CGSize(width: 520, height: 480))
    }

    func bulkDeleteSheet() async throws -> ScreenHost {
        let keyspace = BrowserKeyspace([0: ["tmp:1", "tmp:2", "user:1"]])
        let list = keyspace.list(readOnly: false)
        let filter = KeyFilterModel(list: list) { _ in }
        filter.patternText = "tmp:*"
        await filter.applyPattern()
        let browser = BrowserModel(list: list, filter: filter, database: 0)
        await browser.start()
        await browser.requestBulkDelete()
        let model = try XCTUnwrap(browser.bulkDelete)
        await model.loadSample()
        return host(BulkDeleteSheet(model: model) {}, size: CGSize(width: 560, height: 560))
    }

    func typedConfirmationSheet() -> ScreenHost {
        let profile = SafetyProfile(name: "payments-prod", readOnly: false, production: true, server: "10.0.4.12:6379")
        let model = TypedConfirmationModel(TypedConfirmation(operation: .flushAll, profile: profile, database: 0)) { nil }
        return host(TypedConfirmationSheet(model: model) {}, size: CGSize(width: 520, height: 420))
    }

    // MARK: - Editors

    /// The editor shell over a loaded key of `type`; `edited` leaves an unsaved change so the save bar shows, and
    /// `partial` makes the string 2 MiB, so only its first MiB loads (FR-ED01).
    func editor(_ type: KeyType, readOnly: Bool = false, edited: Bool = false, partial: Bool = false) async -> (ScreenHost, EditorSession) {
        let server: TransactionalKeyspace
        let key: String
        switch type {
        case .string where partial: server = TransactionalKeyspace(["blob": String(repeating: "x", count: 2 << 20)]); key = "blob"
        case .hash: server = TransactionalKeyspace(hashes: ["user:1042": [("name", "Ada"), ("city", "London")]]); key = "user:1042"
        case .list: server = TransactionalKeyspace(lists: ["queue:jobs": ["a", "b", "c"]]); key = "queue:jobs"
        case .set: server = TransactionalKeyspace(sets: ["tags": ["red", "blue"]]); key = "tags"
        case .zset: server = TransactionalKeyspace(zsets: ["board": [("ada", 3), ("bob", 1.5)]]); key = "board"
        case .stream: server = TransactionalKeyspace(streams: ["events": [("1700000000000-0", [("type", "login")])]]); key = "events"
        default: server = TransactionalKeyspace(["greeting": "hello"]); key = "greeting"
        }
        let session = server.session(key, type: type, readOnly: readOnly)
        await session.load()
        if edited {
            if type == .string {
                session.viewer.edit("hello, world")
            } else if let row = session.loaded?.rows.first {
                session.select(row.id); session.viewer.edit("changed")
            }
        }
        let screen = host(EditorShell(session: session).frame(width: 760, height: 700), size: CGSize(width: 760, height: 700))
        screen.settle(0.3)
        return (screen, session)
    }

    func renameSheet() async -> ScreenHost {
        let session = TransactionalKeyspace(["greeting": "hello"]).session("greeting")
        await session.load()
        return host(RenameKeySheet(session: session), size: CGSize(width: 520, height: 320))
    }

    func ttlSheet() async -> ScreenHost {
        let session = TransactionalKeyspace(["greeting": "hello"]).session("greeting")
        await session.load()
        return host(SetTTLSheet(session: session), size: CGSize(width: 520, height: 360))
    }

    // MARK: - Console, Info

    func info() async throws -> ScreenHost {
        let text = try String(contentsOf: AuditScreens.fixtures.appendingPathComponent("INFO/full/redis-7.2.txt"), encoding: .utf8)
        let model = InfoServer(text: text).model(sleeper: ManualSleeper())
        await model.refresh()
        let screen = host(InfoPane(model: model).frame(width: 1000, height: 760), size: CGSize(width: 1000, height: 760))
        screen.settle(0.3)
        return screen
    }

    // MARK: - Sheets and overlays

    func connectionSheet() async -> ScreenHost {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: store)
        return host(ConnectionSheet(model: model), size: CGSize(width: 620, height: 760))
    }

    func sshPrompt(_ text: String) -> ScreenHost {
        let prompt = SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: AskpassPrompt.classify(text, kind: nil))
        return host(SSHPromptSheet(prompt: prompt) { _ in }, size: CGSize(width: 560, height: 420))
    }

    func commandPalette() -> ScreenHost {
        let model = CommandPaletteModel {
            ["Browser", "Console", "Info"].map { title in PaletteEntry(PaletteItem(id: "command:\(title)", kind: .action, title: title, subtitle: "View")) {} }
        }
        model.toggle()
        return host(CommandPaletteOverlay(model: model).frame(width: 900, height: 600), size: CGSize(width: 900, height: 600))
    }

    func keyboardSettings() -> ScreenHost {
        let bindings = ShortcutBindings(defaults: UserDefaults(suiteName: "keel-audit-\(UUID().uuidString)")!)
        return host(KeyboardSettingsView(model: KeyboardSettingsModel(bindings: bindings), bindings: bindings), size: CGSize(width: 640, height: 560))
    }

    /// The Settings window on `pane` (FR-AP09).
    func settings(_ pane: SettingsDraft.Pane) -> ScreenHost {
        let bindings = ShortcutBindings(defaults: UserDefaults(suiteName: "keel-audit-\(UUID().uuidString)")!)
        let draft = SettingsDraft(settings: SettingsModel(persistence: nil, applyAppearance: { _ in }))
        draft.pane = pane
        return host(SettingsView(draft: draft, keyboard: KeyboardSettingsModel(bindings: bindings)), size: CGSize(width: 640, height: 560))
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
}

/// AC1 (NFR-AX01, DS-04): every control on every screen has a name VoiceOver reads, and status is words, never only
/// a color.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    private var directory: URL!
    private var screens: AuditScreens!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        screens = AuditScreens(directory: directory)
    }

    override func tearDown() async throws {
        screens.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func assertLabeled(_ screen: ScreenHost, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(screen.nodes.contains { $0.isControl }, "\(name): the audit found no control, so it read nothing", file: file, line: line)
        for node in screen.unlabeledControls { XCTFail("\(name): unlabeled \(node.description)", file: file, line: line) }
    }

    private func assertSays(_ screen: ScreenHost, _ text: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(screen.nodes(saying: text).isEmpty, "\(why): nothing says “\(text)”", file: file, line: line)
    }

    func testEveryControlHasLabel() async throws {
        let empty = screens.emptyWindow()
        XCTAssertTrue(empty.unlabeledControls.isEmpty)
        assertSays(empty, RootView.accessibilityLabel, "Empty window")
        for mode in TabMode.allCases {
            let (window, _) = try await screens.mainWindow(mode: mode)
            assertLabeled(window, "Main window, \(mode.title)")
            window.close()
        }
        assertLabeled(await screens.keyList(), "Key list")
        assertLabeled(await screens.newKeySheet(), "New key sheet")
        assertLabeled(try await screens.bulkDeleteSheet(), "Bulk delete sheet")
        assertLabeled(screens.typedConfirmationSheet(), "Typed confirmation sheet")
        for type in [KeyType.string, .hash, .list, .set, .zset, .stream] {
            let (editor, _) = await screens.editor(type, edited: true)
            assertLabeled(editor, "\(type) editor")
            editor.close()
            let (readOnly, _) = await screens.editor(type, readOnly: true)
            assertLabeled(readOnly, "Read-only \(type) editor")
            readOnly.close()
        }
        let (partial, _) = await screens.editor(.string, partial: true)
        assertLabeled(partial, "Partially loaded string")
        assertLabeled(await screens.renameSheet(), "Rename sheet")
        assertLabeled(await screens.ttlSheet(), "Set TTL sheet")
        assertLabeled(try await screens.info(), "Info")
        assertLabeled(await screens.connectionSheet(), "Connection sheet")
        assertLabeled(screens.sshPrompt("app@bastion's password: "), "SSH password prompt")
        assertLabeled(
            screens.sshPrompt("The authenticity of host 'bastion (10.0.0.5)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "),
            "SSH host key prompt")
        assertLabeled(screens.commandPalette(), "Command palette")
        assertLabeled(screens.keyboardSettings(), "Keyboard settings")
        for pane in SettingsDraft.Pane.allCases { assertLabeled(screens.settings(pane), "\(pane.title) settings") }
    }

    /// The audit itself fails on what it is meant to catch, so a passing run means something.
    func testAuditCatchesUnlabeledControls() {
        let screen = ScreenHost(
            VStack {
                Button {
                } label: {
                    Circle().frame(width: 8, height: 8)
                }
                TextField("", text: .constant("value"))
                Button("Named") {}
            }, size: CGSize(width: 300, height: 200))
        defer { screen.close() }
        XCTAssertEqual(screen.unlabeledControls.map(\.role), [.button, .textField])
    }

    /// Connection, read-only, production, TLS not verified, partial load, type and unsaved state are all spoken in words
    /// (NFR-AX01); the label dots and badge fills only repeat them.
    func testStatusIsNotColorOnly() async throws {
        let (window, _) = try await screens.mainWindow()
        assertSays(window, "payments-prod, Production, connected", "sidebar: label and connection status")
        assertSays(window, "local-dev, Green, not connected", "sidebar: a label's color has a name")
        assertSays(window, "payments-prod, connected, TLS not verified", "the tab: connection and TLS status")
        assertSays(window, "api-staging, connected", "a background tab's status")
        assertSays(window, ProductionChrome.stripText(readOnly: true), "the production strip")
        assertSays(window, ProductionChrome.tlsNotVerified, "the toolbar's TLS status")
        XCTAssertFalse(window.nodes(saying: ProductionChrome.tlsNotVerified).filter { $0.role == .staticText || $0.role == .image }.isEmpty, "shown as text")
        window.close()

        // A key row's type is in its spoken name ("k20, hash"; KeyListRowMetadataReviewTests); a folder says its count.
        assertSays(await screens.keyList(), "user, 2 keys", "a folder row")

        let (edited, _) = await screens.editor(.hash, edited: true)
        assertSays(edited, "Field name, Value changed, changed", "a changed row says so; the accent dot only repeats it")
        assertSays(edited, "1 unsaved change", "the save bar")
        assertSays(edited, "hash", "the type badge")
        edited.close()

        let (readOnly, _) = await screens.editor(.hash, readOnly: true)
        assertSays(readOnly, "Read-only", "a read-only editor says so beside the lock")
        readOnly.close()

        let (partial, _) = await screens.editor(.string, partial: true)
        assertSays(partial, "Read-only until fully loaded", "a partial load")
        partial.close()
    }
}

/// AC2 (NFR-AX02): every screen is operable from the keyboard. Tab reaches each text field, list and table in reading
/// order and wraps around; Full Keyboard Access adds the buttons between these stops.
@MainActor
final class KeyboardNavigationTests: XCTestCase {
    private var directory: URL!
    private var screens: AuditScreens!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        screens = AuditScreens(directory: directory)
    }

    override func tearDown() async throws {
        screens.closeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tab from the window's start visits `expected` in order, then wraps to the first stop.
    private func assertTabOrder(_ screen: ScreenHost, _ expected: [String], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let stops = screen.tabStops(limit: expected.count + 1)
        XCTAssertEqual(stops, expected + [expected[0]], "\(name)", file: file, line: line)
    }

    func testTabOrderPerScreen() async throws {
        let (window, _) = try await screens.mainWindow()
        assertTabOrder(window, ["Connections", "Filter keys by pattern", "Keys"], "Main window: sidebar, filter, key list")
        window.close()

        let (hash, _) = await screens.editor(.hash)
        assertTabOrder(hash, ["Filter loaded fields", "Fields"], "Hash editor: filter, then the table")
        hash.close()
        for (type, table) in [(KeyType.list, "Items"), (.set, "Members"), (.zset, "Members"), (.stream, "Entries")] {
            let (editor, _) = await screens.editor(type)
            XCTAssertTrue(editor.tabStops(limit: 3).contains(table), "\(type) editor: Tab reaches the table")
            editor.close()
        }

        assertTabOrder(
            await screens.connectionSheet(), ["New Connection", "Connection URL", "Name", "Host", "Port", "Username", "Password, saved in Keychain"],
            "Connection sheet: the form (⌘V target), then its fields top to bottom")
        assertTabOrder(screens.typedConfirmationSheet(), ["Type payments-prod to confirm."], "Typed confirmation: the one field")
        XCTAssertEqual(screens.commandPalette().tabStops(limit: 2).count, 2)
    }

    /// The value text view keeps Tab as a character (values may hold tabs); ⌃Tab leaves it, as in every Mac text view.
    func testControlTabLeavesTheValueEditor() async {
        let (editor, _) = await screens.editor(.hash, edited: true)
        let stops = editor.tabStops(limit: 4)
        XCTAssertEqual(stops, ["Filter loaded fields", "Fields", "Value as Text", "Value as Text"], "Tab stays in the value")
        editor.pressTab(.control)
        XCTAssertEqual(editor.focusedName, "Filter loaded fields", "⌃Tab moves on, around the loop")
        editor.pressTab()
        editor.pressTab()
        XCTAssertEqual(editor.focusedName, "Value as Text")
        editor.pressTab([.control, .shift])
        XCTAssertNotEqual(editor.focusedName, "Value as Text", "⌃⇧Tab leaves it too")
    }

    /// ↑/↓ on a focused editor table select rows; the arrows never wrap.
    func testArrowsMoveTheSelectionInAFocusedTable() async {
        let (editor, session) = await screens.editor(.hash)
        XCTAssertEqual(editor.tabStops(limit: 2).last, "Fields")
        XCTAssertNil(session.selectedRow)
        editor.pressDown()
        XCTAssertEqual(session.selectedRow, Data("city".utf8), "↓ selects the first row")
        editor.pressDown()
        XCTAssertEqual(session.selectedRow, Data("name".utf8))
        editor.pressDown()
        XCTAssertEqual(session.selectedRow, Data("name".utf8), "stays on the last row")
        editor.pressUp()
        XCTAssertEqual(session.selectedRow, Data("city".utf8))
        XCTAssertEqual(session.viewer.title, "city", "the selected field opens in the viewer")
    }

    /// Scenario step 6 by keyboard: Tab to the sidebar, ↓ selects a connection, ⌘I opens Edit Connection.
    func testSidebarEditsTheSelectedConnectionByKeyboard() async throws {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let profile = try await store.create(ConnectionSettings(name: "local-dev"))
        let presenter = ConnectionSheetPresenter(store: store, tester: FakeConnectionTester())
        let sidebar = SidebarModel(store: store, tabs: ConnectionTabs(), sheets: presenter, copy: { _ in })
        await sidebar.reload()
        let screen = ScreenHost(SidebarView(model: sidebar).frame(height: 500), size: CGSize(width: 260, height: 500))
        defer { screen.close() }
        XCTAssertEqual(screen.tabStops(limit: 1), ["Connections"])
        screen.pressDown()
        XCTAssertEqual(sidebar.selectedProfileID, profile.id)
        screen.press(keyCode: 34, characters: "i", modifiers: .command)
        // The sheet is prepared in a task on this actor: yield to it rather than spin the run loop.
        for _ in 0..<200 where presenter.model == nil { try await Task.sleep(for: .milliseconds(5)) }
        if case .edit(let editing)? = presenter.model?.mode { XCTAssertEqual(editing.id, profile.id) } else { XCTFail("not the Edit sheet") }
    }

    func testRowNavigationSteps() {
        XCTAssertNil(RowNavigation.step([Int](), from: nil, by: 1))
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: nil, by: 1), 1)
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: nil, by: -1), 3)
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: 2, by: 1), 3)
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: 3, by: 1), 3)
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: 1, by: -1), 1)
        XCTAssertEqual(RowNavigation.step([1, 2, 3], from: 9, by: 1), 1, "a selection filtered out starts over")
        XCTAssertEqual(TableSpeech.row(["Field": "city", "Value": "London"], changed: true), "Field city, Value London, changed")
    }

    /// The key list draws its focus ring inside the pane, so the scroll view never clips it.
    func testKeyListShowsFocus() async {
        let screen = await screens.keyList()
        func find(_ view: NSView) -> KeyListOutlineView? { (view as? KeyListOutlineView) ?? view.subviews.lazy.compactMap(find).first }
        let outline = try? XCTUnwrap(find(screen.host))
        guard let outline else { return }
        XCTAssertNotEqual(outline.focusRingType, .none)
        XCTAssertFalse(outline.visibleRect.isEmpty, "hosted on screen")
        XCTAssertTrue(outline.visibleRect.contains(outline.focusRingMaskBounds), "the ring stays inside the visible pane")
        XCTAssertEqual(outline.tableColumns.first?.title, "Key", "VoiceOver names the one column")
    }
}

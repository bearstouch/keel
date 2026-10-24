import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// KEEL-049 AC1, AC3, FR-AP09: the Settings window edits a draft; Cancel restores the exact prior state, Apply makes
/// it current and saves it in `settings.json`.
@MainActor
final class SettingsDraftTests: XCTestCase {
    private var directory: URL!
    /// Every appearance the model gave `NSApp`, in order (nil: follow macOS).
    private var applied: [NSAppearance.Name?] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        applied = []
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private var file: URL { directory.appendingPathComponent("settings.json") }

    private func model() -> SettingsModel {
        SettingsModel(persistence: Persistence(directory: directory, debounce: .zero), applyAppearance: { [weak self] in self?.applied.append($0?.name) }, systemIsDark: { false })
    }

    /// Settings that differ from the defaults in every pane.
    private static let saved = SettingsDocument(
        theme: .dark, restoresWindows: false, browser: BrowserSettings(separator: "/", pageSize: 500, autoPageLimit: 2_000_000),
        editors: EditorSettings(defaultViewer: .hex), console: ConsoleSettings(protocolVersion: 2),
        advanced: AdvancedSettings(connectTimeoutMilliseconds: 5_000, commandTimeoutMilliseconds: 60_000, setsClientName: false))

    /// Every field of the draft changed, the theme previewed live, then Cancel: the draft, the applied settings, what
    /// other actors read, the appearance and the file are all exactly as before.
    func testCancelRestoresPriorState() async throws {
        let bytes = try PersistenceCodec.encode(Self.saved)
        try bytes.write(to: file)
        let settings = model()
        await settings.load()
        XCTAssertEqual(settings.applied, Self.saved)
        XCTAssertEqual(applied.last, .darkAqua)

        let draft = SettingsDraft(settings: settings)
        draft.document.theme = .system
        XCTAssertEqual(applied.last, .some(nil), "the theme is previewed as it is chosen")
        draft.document.restoresWindows = true
        draft.document.browser = BrowserSettings(separator: "::", pageSize: 10_000, autoPageLimit: 100_000)
        draft.document.editors.defaultViewer = .raw
        draft.document.console.protocolVersion = 3
        draft.document.advanced = AdvancedSettings(connectTimeoutMilliseconds: 1_000, commandTimeoutMilliseconds: 5_000, setsClientName: true)
        XCTAssertTrue(draft.canApply)
        XCTAssertEqual(settings.applied, Self.saved, "nothing applies before Apply")
        XCTAssertEqual(settings.snapshot.current, Self.saved, "new scans and connects still read the applied settings")

        draft.cancel()
        XCTAssertEqual(draft.document, Self.saved)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(settings.applied, Self.saved)
        XCTAssertEqual(settings.snapshot.current, Self.saved)
        XCTAssertEqual(applied.last, .darkAqua, "the theme in use is back")
        await settings.flush()
        XCTAssertEqual(try Data(contentsOf: file), bytes, "a preview is never persisted")
    }

    /// Apply makes the draft current at once (the theme too) and writes it; the next launch reads it back.
    func testApplyPersists() async throws {
        let settings = model()
        await settings.load()
        let draft = SettingsDraft(settings: settings)
        draft.document = Self.saved
        XCTAssertTrue(draft.apply())
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(settings.applied, Self.saved)
        XCTAssertEqual(settings.snapshot.current, Self.saved)
        XCTAssertEqual(applied.last, .darkAqua)
        await settings.flush()
        XCTAssertEqual(try PersistenceCodec.decode(SettingsDocument.self, from: Data(contentsOf: file)), Self.saved)

        let next = model()
        await next.load()
        XCTAssertEqual(next.applied, Self.saved)
        XCTAssertEqual(next.snapshot.current, Self.saved)
    }

    /// An invalid separator says why and applies nothing; the other changes wait in the draft.
    func testInvalidSeparatorIsRefused() async {
        let settings = model()
        await settings.load()
        let draft = SettingsDraft(settings: settings)
        for separator in ["", "abcde", "a\tb"] {
            draft.document.browser.separator = separator
            XCTAssertNotNil(draft.problem, separator)
            XCTAssertFalse(draft.canApply)
            XCTAssertFalse(draft.apply())
            XCTAssertEqual(settings.applied, SettingsDocument())
        }
        draft.document.browser.separator = "→"  // 3 bytes in UTF-8
        XCTAssertNil(draft.problem)
        XCTAssertTrue(draft.apply())
        XCTAssertEqual(settings.applied.browser.separator, "→")
    }

    /// Closing the window (red button, ⌘W, Esc) is Cancel; reopening starts from the applied settings.
    func testClosingTheWindowCancels() async {
        let settings = model()
        await settings.load()
        let draft = SettingsDraft(settings: settings)
        let window = SettingsWindow.make(draft: draft, keyboard: KeyboardSettingsModel(bindings: ShortcutBindings(defaults: UserDefaults(suiteName: "keel-settings-\(UUID())")!)))
        draft.document.theme = .dark
        draft.document.browser.pageSize = 100
        window.close()
        XCTAssertEqual(draft.document, SettingsDocument())
        XCTAssertEqual(applied.last, .aqua)
        XCTAssertEqual(settings.applied, SettingsDocument())
    }

    /// View → Theme while the window is open changes the applied theme; Cancel then keeps that one.
    func testMenuThemeChangeSurvivesCancel() async {
        let settings = model()
        await settings.load()
        let draft = SettingsDraft(settings: settings)
        draft.document.browser.pageSize = 100
        settings.setTheme(.dark)
        draft.cancel()
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(draft.document.theme, .dark)
        XCTAssertEqual(applied.last, .darkAqua)
    }

    /// Reopening the window after View → Theme changed the theme starts from it, so Apply never brings the old one back.
    func testReopeningStartsFromTheAppliedSettings() async {
        let settings = model()
        await settings.load()
        let draft = SettingsDraft(settings: settings)
        draft.cancel()
        settings.setTheme(.dark)
        XCTAssertTrue(draft.hasChanges, "the closed window's draft is stale")
        draft.begin()
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.document.theme, .dark)
    }
}

import XCTest
@testable import KeelCore

/// A stand-in action table: Keel's own (FR-AP02) arrives with KEEL-048. `clearConsole` is a later default.
private enum TestAction: String, ShortcutAction {
    case newTab, refresh, toggleSidebar, renameKey, clearConsole, disconnect

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .refresh: "Refresh"
        case .toggleSidebar: "Hide Sidebar"
        case .renameKey: "Rename Key…"
        case .clearConsole: "Clear Console"
        case .disconnect: "Disconnect"
        }
    }

    var defaultChord: KeyChord? {
        switch self {
        case .newTab: KeyChord("t")
        case .refresh: KeyChord("r")
        case .toggleSidebar: KeyChord("s", [.command, .control])
        case .renameKey: KeyChord("e")
        case .clearConsole: KeyChord("k", [.command, .option])
        case .disconnect: nil
        }
    }

    static var laterDefaults: [Self] { [.clearConsole] }
}

private typealias Map = ShortcutMap<TestAction>
private typealias Issue = ShortcutIssue<TestAction>
private typealias Settings = ShortcutSettings<TestAction>

final class KeyboardShortcutTests: XCTestCase {
    func testRejectShortcutCollision() throws {
        let previous = Map.defaults
        XCTAssertThrowsError(try previous.binding(.newTab, to: KeyChord("r"))) { error in
            XCTAssertEqual(error as? Issue, .conflict(KeyChord("r"), [.newTab, .refresh]))
            let message = (error as? Issue)?.description ?? ""
            XCTAssertTrue(message.contains("New Tab") && message.contains("Refresh"), message)
        }
        XCTAssertEqual(previous, Map.defaults)
        XCTAssertEqual(previous[.newTab], KeyChord("t"))

        // A draft may conflict while editing; validation names both actions once.
        let draft = previous.assigning(KeyChord("r"), to: .newTab)
        XCTAssertEqual(draft.issues(), [.conflict(KeyChord("r"), [.newTab, .refresh])])
        // Swapping in two steps resolves the conflict.
        let swapped = draft.assigning(KeyChord("t"), to: .refresh)
        XCTAssertEqual(swapped.issues(), [])
        XCTAssertEqual(swapped.action(for: KeyChord("t")), .refresh)
    }

    func testDefaultsAreConflictFreeAndDescribed() {
        let map = Map.defaults
        XCTAssertEqual(map.issues(), [])
        XCTAssertNil(map[.disconnect], "An action without a default stays unbound")
        XCTAssertEqual(KeyChord("D", [.command, .shift]).description, "⇧⌘D")
        XCTAssertEqual(KeyChord("left", [.command, .option, .control]).description, "⌃⌥⌘←")
    }

    func testConsoleControlAndNativeEditingChordsAreProtected() {
        let map = Map.defaults
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("l", [.control]))) {
            XCTAssertEqual($0 as? Issue, .requiresCommand(KeyChord("l", [.control]), .newTab))
            XCTAssertTrue(($0 as? Issue)?.description.contains("console") ?? false)
        }
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("v"))) {
            XCTAssertEqual($0 as? Issue, .reserved(KeyChord("v"), .newTab, reservedFor: "Paste"))
        }
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("q"))) {
            XCTAssertEqual($0 as? Issue, .reserved(KeyChord("q"), .newTab, reservedFor: "Quit Keel"))
        }
        XCTAssertThrowsError(try map.binding(.newTab, to: KeyChord("bogus"))) {
            XCTAssertEqual($0 as? Issue, .unsupportedKey(KeyChord("bogus"), .newTab))
        }
        // Clearing is explicit and leaves the command available from its menu.
        XCTAssertNil(try map.binding(.renameKey, to: nil)[.renameKey])
    }

    func testSettingsStoreOnlyOverridesAndIgnoreUnknownActions() throws {
        var settings = Settings()
        settings.shortcuts = settings.shortcuts.assigning(KeyChord("k", [.command, .shift]), to: .disconnect).assigning(nil, to: .renameKey)
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["overrides"] as? [String: Any])?.keys.sorted(), ["disconnect", "renameKey"])
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)

        let future = Data(#"{"overrides":{"teleport":{"chord":{"key":"p","modifiers":1}}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: future), Settings())
    }

    func testANewDefaultYieldsToAChordTheUserAlreadyChose() throws {
        // Saved before ⌥⌘K became Clear Console: the user's choice wins and the new action starts unbound.
        let data = Data(#"{"overrides":{"renameKey":{"chord":{"key":"k","modifiers":5}}}}"#.utf8)
        let loaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(loaded.shortcuts[.renameKey], KeyChord("k", [.command, .option]))
        XCTAssertNil(loaded.shortcuts[.clearConsole])
        XCTAssertTrue(loaded.shortcuts.issues().isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(loaded)), loaded)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(#"{"overrides":{}}"#.utf8)).shortcuts[.clearConsole], KeyChord("k", [.command, .option]))
    }
}

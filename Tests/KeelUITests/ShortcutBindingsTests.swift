import AppKit
import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class ShortcutBindingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "com.bearstouch.keel.tests.shortcuts.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suiteName) }

    @MainActor func testConflictRejected() throws {
        let bindings = ShortcutBindings(defaults: defaults)
        // AC2 / FR-AP02: ⌘R belongs to Refresh; binding it to New Tab is refused, naming Refresh, and nothing changes.
        XCTAssertThrowsError(try bindings.bind(.newTab, to: KeyChord("r"))) { error in
            let issue = error as? KeelShortcutIssue
            XCTAssertEqual(issue, .conflict(KeyChord("r"), [.newTab, .refresh]))
            XCTAssertEqual(issue?.rejection(for: .newTab), "⌘R is already used by Refresh. Choose another shortcut or change that one first.")
        }
        XCTAssertEqual(bindings.map, .defaults)
        XCTAssertNil(defaults.data(forKey: ShortcutBindings.defaultsKey), "A rejected chord saves nothing")

        // Settings → Keyboard says the same and keeps the old chord.
        let settings = KeyboardSettingsModel(bindings: bindings)
        settings.startRecording(.newTab)
        XCTAssertFalse(settings.record(KeyChord("r")))
        XCTAssertNil(settings.recording)
        XCTAssertTrue(settings.message?.contains("Refresh") ?? false, settings.message ?? "")
        XCTAssertEqual(bindings[.newTab], KeyChord("t"))

        // A free chord is taken, saved, and survives relaunch; the message clears.
        settings.startRecording(.newTab)
        XCTAssertTrue(settings.record(KeyChord("y", [.command, .option])))
        XCTAssertNil(settings.message)
        XCTAssertEqual(ShortcutBindings(defaults: defaults)[.newTab], KeyChord("y", [.command, .option]))
        // Swapping takes two steps: clear one, then reuse its chord.
        settings.clear(.refresh)
        settings.startRecording(.newKey)
        XCTAssertTrue(settings.record(KeyChord("r")))
        XCTAssertEqual(ShortcutBindings(defaults: defaults)[.newKey], KeyChord("r"))
        XCTAssertNil(ShortcutBindings(defaults: defaults)[.refresh])
        // Refresh's default is taken now, so restoring it is refused naming New Key…
        settings.restoreDefault(.refresh)
        XCTAssertTrue(settings.message?.contains("New Key…") ?? false, settings.message ?? "")
        settings.restoreAllDefaults()
        XCTAssertEqual(ShortcutBindings(defaults: defaults).map, .defaults)

        // A saved map that no longer validates is not used: the defaults apply and the saved value stays.
        let broken = Data(#"{"overrides":{"newTab":{"chord":{"key":"r","modifiers":1}}}}"#.utf8)
        defaults.set(broken, forKey: ShortcutBindings.defaultsKey)
        XCTAssertEqual(ShortcutBindings(defaults: defaults).map, .defaults)
        XCTAssertEqual(defaults.data(forKey: ShortcutBindings.defaultsKey), broken)
    }

    /// The "Default shortcuts" table in 03 Functional requirements, read from the spec itself, row by row.
    @MainActor func testDefaultsMatchSpecTable() throws {
        let rows: [String: [KeelShortcut?]] = [
            "New window / new tab (connection picker)": [.newWindow, .newTab], "New key (Browser mode)": [.newKey],
            "Close tab / close window": [.closeTab, .closeWindow], "Command palette": [.commandPalette], "Filter keys": [.filterKeys],
            "Refresh": [.refresh], "Browser / Console / Info mode": [.browserMode, .consoleMode, .infoMode],
            "Toggle console panel (Browser)": [.toggleConsolePanel], "Next / previous tab": [.nextTab, .previousTab],
            "Select db0–db9": (0...9).map(KeelShortcut.database), "Toggle tree / flat": [.toggleTreeFlat],
            // Revert keeps ⌘Z as a fixed command (nil here), checked against the fixed list below.
            "Save value / revert": [.saveChanges, nil], "Delete selected key(s)": [.deleteKeys], "Rename key / set TTL": [.renameKey, .setTTL],
            "Stop streaming command": [.stopCommand], "Clear console": [.clearConsole], "Zoom data font": [.zoomIn, .zoomOut, .zoomReset],
            "Disconnect / reconnect": [.disconnect, .reconnect], "Hide / show sidebar": [.toggleSidebar]
        ]
        let spec = try String(contentsOf: Self.specURL, encoding: .utf8)
        let table = try XCTUnwrap(spec.components(separatedBy: "### Default shortcuts").dropFirst().first?.components(separatedBy: "\n\n").dropFirst().first)
        var covered: [KeelShortcut] = []
        var parsedRows = 0
        for line in table.split(separator: "\n") where !line.hasPrefix("| Action") && !line.hasPrefix("| ---") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 2 else { XCTFail("Unexpected row \(line)"); continue }
            let actions = try XCTUnwrap(rows[cells[0]], "No action mapped for spec row “\(cells[0])”")
            let chords = Self.chords(cells[1])
            XCTAssertEqual(chords.count, actions.count, cells[0])
            for (action, chord) in zip(actions, chords) {
                if let action {
                    XCTAssertEqual(action.defaultChord?.description, chord, "\(action) in “\(cells[0])”")
                    covered.append(action)
                } else {
                    XCTAssertEqual(KeelShortcut.fixed.first { $0.title == "Revert Changes" }?.chord.description, chord)
                }
            }
            parsedRows += 1
        }
        XCTAssertEqual(parsedRows, rows.count)
        XCTAssertEqual(Set(covered), Set(KeelShortcut.allCases), "Every rebindable command is in the spec table, and only those")
        XCTAssertEqual(covered.count, KeelShortcut.allCases.count)
        XCTAssertEqual(KeelShortcutMap.defaults.issues(), [], "The defaults are conflict free")

        // AC4: every configurable shortcut includes ⌘, and a chord without it is refused.
        XCTAssertTrue(KeelShortcut.allCases.allSatisfy { $0.defaultChord?.modifiers.contains(.command) == true })
        XCTAssertThrowsError(try KeelShortcutMap.defaults.binding(.clearConsole, to: KeyChord("l", [.control]))) {
            XCTAssertEqual($0 as? KeelShortcutIssue, .requiresCommand(KeyChord("l", [.control]), .clearConsole))
        }
        // AC3: the fixed commands are not rebindable, and their chords can't be taken. The spec's sentence names them all.
        let fixedSentence = try XCTUnwrap(spec.components(separatedBy: "\n").first { $0.contains("can't be rebound") })
        for fixed in KeelShortcut.fixed {
            XCTAssertNil(KeelShortcut.allCases.first { $0.title == fixed.title }, "\(fixed.title) is not rebindable")
            XCTAssertNotNil(KeelShortcutMap.reserved[fixed.chord], "\(fixed.chord) is reserved")
            XCTAssertThrowsError(try KeelShortcutMap.defaults.binding(.refresh, to: fixed.chord)) {
                guard case .reserved = $0 as? KeelShortcutIssue else { return XCTFail("\(fixed.chord): \($0)") }
            }
        }
        for name in ["Settings", "Hide", "Quit", "Undo/Redo", "Cut", "Copy", "Paste", "Select All", "Minimize"] {
            XCTAssertTrue(fixedSentence.contains(name), name)
        }
    }

    func testMenuKeyEquivalents() {
        XCTAssertEqual(KeyChord("delete").menuKeyEquivalent.key, "\u{8}")
        XCTAssertEqual(KeyChord("delete").menuKeyEquivalent.modifiers, .command)
        let shifted = KeyChord("]", [.command, .shift]).menuKeyEquivalent
        XCTAssertEqual(shifted.key, "]")
        XCTAssertEqual(shifted.modifiers, [.command, .shift])
        XCTAssertEqual(KeyChord("f5", [.command, .control, .option]).menuKeyEquivalent.key, String(UnicodeScalar(NSF5FunctionKey)!))
        // A recorded ⌘⌫ (key code 51) reads as the named key, whatever the layout.
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "\u{8}",
            charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)
        XCTAssertEqual(event.flatMap(KeyChord.init(event:)), KeyChord("delete"))
    }

    /// The spec's chord cell as `KeyChord.description` writes it: "⌥⌘0 – ⌥⌘9" expands, a note in parentheses goes,
    /// and the spec's minus sign is the "-" key.
    private static func chords(_ cell: String) -> [String] {
        let text = cell.components(separatedBy: " (").first ?? cell
        if text.contains(" – ") {
            let ends = text.components(separatedBy: " – ")
            let prefix = String(ends[0].dropLast())
            return (0...9).map { prefix + String($0) }
        }
        return text.components(separatedBy: " / ").map { $0.replacingOccurrences(of: "−", with: "-") }
    }

    private static var specURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/03-functional-requirements.md")
    }
}

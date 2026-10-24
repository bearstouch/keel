import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// KEEL-044 AC4, FR-AP04, DS-11/12/13: Light / Dark / System, applied live and saved in `settings.json`; Increase
/// Contrast and Reduce Motion.
@MainActor
final class ThemeTests: XCTestCase {
    private var directory: URL!
    /// Every appearance the model gave `NSApp`, in order (nil: follow macOS).
    private var applied: [NSAppearance.Name?] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-theme-\(UUID().uuidString)")
        applied = []
        KeelTheme.increasesContrast = false
    }

    override func tearDown() async throws {
        KeelTheme.increasesContrast = false
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(systemIsDark: Bool = false) -> SettingsModel {
        SettingsModel(persistence: Persistence(directory: directory, debounce: .zero), applyAppearance: { [weak self] in self?.applied.append($0?.name) }, systemIsDark: { systemIsDark })
    }

    /// The sRGB value a dynamic color takes when drawn in `appearance`.
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> UInt32 {
        var value: UInt32 = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            value = UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
        }
        return value
    }

    func testSystemFollowsAppearance() async {
        XCTAssertNil(ThemeChoice.system.appearance, "System leaves the app on macOS's appearance")
        XCTAssertEqual(ThemeChoice.light.appearance?.name, .aqua)
        XCTAssertEqual(ThemeChoice.dark.appearance?.name, .darkAqua)
        // Tokens resolve per appearance, so the same color objects follow macOS when it switches.
        XCTAssertEqual(resolved(Tokens.NS.bg, in: .aqua), 0xFFFFFF)
        XCTAssertEqual(resolved(Tokens.NS.bg, in: .darkAqua), 0x1E1E1E)
        XCTAssertEqual(resolved(Tokens.NS.color(.sidebar), in: .aqua), 0xFBEEEC)
        XCTAssertEqual(resolved(Tokens.NS.color(.sidebar), in: .darkAqua), 0x29292B)
        XCTAssertEqual(resolved(Tokens.NS.badge(.string).fg, in: .darkAqua), 0x8BB8F0)
        XCTAssertEqual(resolved(ConsoleTheme.background, in: .aqua), 0x151719, "the console is dark in both themes")
        XCTAssertEqual(resolved(ConsoleTheme.background, in: .darkAqua), 0x151719)

        let settings = model()
        await settings.load()
        settings.setTheme(.system)
        XCTAssertEqual(settings.theme, .system)
        XCTAssertEqual(applied, [.aqua, nil], "Light first, then the system's own appearance")
    }

    /// First launch is Light; a switch applies at once and is saved, and the next launch opens in it.
    func testSwitchAppliesLiveAndPersists() async throws {
        let settings = model()
        await settings.load()
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(applied, [.aqua])
        settings.setTheme(.dark)
        XCTAssertEqual(applied, [.aqua, .darkAqua], "applied before anything is saved")
        settings.setTheme(.dark)
        XCTAssertEqual(applied.count, 2, "choosing the current theme again does nothing")
        await settings.flush()
        try await waitForFile()

        applied = []
        let next = model()
        await next.load()
        XCTAssertEqual(next.theme, .dark)
        XCTAssertEqual(applied, [.aqua, .darkAqua])
    }

    /// A theme picked while `settings.json` was still being read wins and is saved.
    func testChoiceBeforeLoadWins() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PersistenceCodec.encode(SettingsDocument(theme: .dark)).write(to: directory.appendingPathComponent("settings.json"))
        let settings = model()
        settings.setTheme(.system)
        await settings.load()
        XCTAssertEqual(settings.theme, .system)
        await settings.flush()
        try await waitForFile()
        let reread = model()
        await reread.load()
        XCTAssertEqual(reread.theme, .system)
    }

    /// An unreadable `settings.json` keeps Light for the run and is never written over (02 → Persistence).
    func testCorruptSettingsAreNotOverwritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: file)
        let settings = model()
        await settings.load()
        XCTAssertEqual(settings.theme, .light)
        settings.setTheme(.dark)
        XCTAssertEqual(applied.last, .darkAqua, "the switch still applies for this run")
        await settings.flush()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try Data(contentsOf: file), Data("{ not json".utf8))
    }

    /// A theme this build doesn't know reads as the default instead of sending the file to recovery.
    func testUnknownThemeReadsAsDefault() throws {
        var data = try PersistenceCodec.encode(SettingsDocument(theme: .dark))
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"dark\"", with: "\"sepia\"").utf8)
        XCTAssertEqual(try PersistenceCodec.decode(SettingsDocument.self, from: data).theme, .light)
    }

    /// DS-12: Increase Contrast swaps the listed tokens at once and repaints through an appearance change.
    func testIncreaseContrastSwapsTokensLive() async {
        let settings = model()
        await settings.load()
        XCTAssertEqual(resolved(Tokens.NS.muted, in: .aqua), 0x4E5B6D)
        applied = []
        settings.accessibilityDisplayOptionsChanged(increasesContrast: true)
        XCTAssertEqual(applied, [.darkAqua, .aqua], "a round trip through the other appearance, ending on the theme")
        XCTAssertEqual(resolved(Tokens.NS.muted, in: .aqua), 0x364152)
        XCTAssertEqual(resolved(Tokens.NS.muted, in: .darkAqua), 0xC7C7CC)
        XCTAssertEqual(resolved(Tokens.NS.fg, in: .aqua), 0x18212F, "tokens without an override keep their value")
        settings.accessibilityDisplayOptionsChanged(increasesContrast: true)
        XCTAssertEqual(applied.count, 2, "no change, no repaint")

        // System in a dark macOS: the round trip goes through light and ends back on "follow macOS".
        let system = model(systemIsDark: true)
        await system.load(); system.setTheme(.system)
        applied = []
        system.accessibilityDisplayOptionsChanged(increasesContrast: false)
        XCTAssertEqual(applied, [.aqua, nil])
        XCTAssertEqual(resolved(Tokens.NS.muted, in: .aqua), 0x4E5B6D)
    }

    /// DS-13: animations are dropped while Reduce Motion is on.
    func testReduceMotionDropsAnimation() {
        XCTAssertNil(Tokens.animation(.easeInOut, reduceMotion: true))
        XCTAssertNotNil(Tokens.animation(.easeInOut, reduceMotion: false))
    }

    private func waitForFile() async throws {
        let file = directory.appendingPathComponent("settings.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

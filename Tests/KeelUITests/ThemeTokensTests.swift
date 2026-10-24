import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// 08 Design → Color as `scripts/generate-design-tokens.py` reads it from the page (Tests/Fixtures/Design/tokens.json).
struct DesignFixture: Decodable {
    struct Badge: Decodable { let text: String, fill: String }
    struct Themed<Value: Decodable>: Decodable { let light: Value, dark: Value }

    let light: [String: String]
    let dark: [String: String]
    let increaseContrast: Themed<[String: String]>
    let console: [String: String]
    let badges: [String: Themed<Badge>]
    let syntax: [String: Themed<String>]
    let labels: [String: Themed<String>]

    static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    static func load() throws -> DesignFixture {
        try JSONDecoder().decode(DesignFixture.self, from: Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/Design/tokens.json")))
    }

    /// "#RRGGBB" or "rgba(r,g,b,a)"; nil for a token reference such as "muted".
    static func swatch(_ text: String) -> Swatch? {
        if text.hasPrefix("#"), let rgb = UInt32(text.dropFirst(), radix: 16) { return Swatch(rgb) }
        guard text.hasPrefix("rgba("), text.hasSuffix(")") else { return nil }
        let parts = text.dropFirst(5).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, let r = UInt32(parts[0]), let g = UInt32(parts[1]), let b = UInt32(parts[2]), let a = Double(parts[3]) else { return nil }
        return Swatch(r << 16 | g << 8 | b, alpha: a)
    }

    static func hex(_ text: String) -> UInt32? { swatch(text).map(\.rgb) }
}

/// KEEL-044 AC1: every `KeelTheme` value is the one the 08 Design page gives, and no token exists on one side only.
final class ThemeTokensTests: XCTestCase {
    func testValuesMatchDesignSpec() throws {
        let fixture = try DesignFixture.load()
        let tokens = Set(KeelTheme.Token.allCases.map(\.rawValue))
        for (variant, page) in [(KeelTheme.Variant.light, fixture.light), (.dark, fixture.dark)] {
            XCTAssertEqual(Set(page.keys), tokens, "palette tokens, dark: \(variant.isDark)")
            for token in KeelTheme.Token.allCases {
                XCTAssertEqual(KeelTheme.value(token, in: variant), page[token.rawValue].flatMap(DesignFixture.swatch), "\(token), dark: \(variant.isDark)")
            }
        }

        // Increase Contrast replaces exactly the listed tokens; the rest keep their theme's value.
        for (isDark, page, base) in [(false, fixture.increaseContrast.light, fixture.light), (true, fixture.increaseContrast.dark, fixture.dark)] {
            let variant = KeelTheme.Variant(isDark: isDark, increasesContrast: true)
            XCTAssertEqual(Set((isDark ? KeelTheme.increasedContrast.dark : KeelTheme.increasedContrast.light).keys.map(\.rawValue)), Set(page.keys))
            for token in KeelTheme.Token.allCases {
                let expected = (page[token.rawValue] ?? base[token.rawValue]).flatMap(DesignFixture.swatch)
                XCTAssertEqual(KeelTheme.value(token, in: variant), expected, "\(token), increased contrast, dark: \(isDark)")
            }
        }

        XCTAssertEqual(Set(fixture.console.keys), Set(KeelTheme.Console.allCases.map(\.rawValue)))
        for token in KeelTheme.Console.allCases { XCTAssertEqual(KeelTheme.console[token], fixture.console[token.rawValue].flatMap(DesignFixture.hex), "console \(token)") }

        let badged = KeyType.allCases.compactMap { type in KeyListRow.badge(type).map { ($0, type) } }
        XCTAssertEqual(Set(fixture.badges.keys), Set(badged.map(\.0)))
        for (title, type) in badged {
            let page = try XCTUnwrap(fixture.badges[title])
            guard let badge = KeelTheme.badge(type) else {
                // OTHER: the page names palette tokens, which the AppKit badge uses.
                XCTAssertEqual([page.light.text, page.light.fill, page.dark.text, page.dark.fill], ["muted", "soft", "muted", "soft"], title)
                continue
            }
            XCTAssertEqual(badge.text.light, DesignFixture.hex(page.light.text), "\(title) light text")
            XCTAssertEqual(badge.fill.light, DesignFixture.hex(page.light.fill), "\(title) light fill")
            XCTAssertEqual(badge.text.dark, DesignFixture.hex(page.dark.text), "\(title) dark text")
            XCTAssertEqual(badge.fill.dark, DesignFixture.hex(page.dark.fill), "\(title) dark fill")
        }

        XCTAssertEqual(Set(fixture.syntax.keys), Set(KeelTheme.Syntax.allCases.map(\.rawValue)))
        for syntax in KeelTheme.Syntax.allCases {
            let pair = try XCTUnwrap(KeelTheme.syntax[syntax]), page = try XCTUnwrap(fixture.syntax[syntax.rawValue])
            XCTAssertEqual([pair.light, pair.dark], [DesignFixture.hex(page.light), DesignFixture.hex(page.dark)], "\(syntax)")
        }

        let labelled = LabelColor.allCases.filter { $0 != .none }
        XCTAssertEqual(Set(fixture.labels.keys), Set(labelled.map(\.rawValue)))
        XCTAssertNil(KeelTheme.label(.none), "None is an empty ring, not a dot")
        for color in labelled {
            let pair = try XCTUnwrap(KeelTheme.label(color)), page = try XCTUnwrap(fixture.labels[color.rawValue])
            XCTAssertEqual([pair.light, pair.dark], [DesignFixture.hex(page.light), DesignFixture.hex(page.dark)], "\(color)")
        }
    }

    /// The fixture is regenerated from the page, never edited by hand: a page change without a regenerated fixture fails.
    func testFixtureMatchesPage() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("python3 is not installed") }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", DesignFixture.repository.appendingPathComponent("scripts/generate-design-tokens.py").path, "--check"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "run scripts/generate-design-tokens.py after editing 08 Design")
    }
}

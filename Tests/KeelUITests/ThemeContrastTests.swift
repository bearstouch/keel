import XCTest

@testable import KeelCore
@testable import KeelUI

/// KEEL-044 AC3, NFR-AX04: the pairs of 08 Design → Contrast pairs, in light, dark and both Increase Contrast variants.
final class ThemeContrastTests: XCTestCase {
    private typealias Token = KeelTheme.Token

    private static let surfaces: [Token] = [.bg, .sheet, .sidebar, .sidebarSelection, .tabBar, .codeBg, .field, .soft, .segBg, .segOn, .card, .selection, .changedRow]
    /// Where status words and the accent appear: not on inputs, segments or the selected sidebar row.
    private static let statusSurfaces: [Token] = [.bg, .sheet, .sidebar, .tabBar, .codeBg, .soft, .card, .selection, .changedRow]

    func testAllPairsMeetThresholds() {
        var failures: [String] = []
        func check(_ name: String, _ foreground: UInt32, _ background: UInt32, _ minimum: Double) {
            let ratio = KeelTheme.contrast(foreground, background)
            if ratio < minimum { failures.append(String(format: "%@: %.2f:1, needs %.1f:1", name, ratio, minimum)) }
        }

        for variant in KeelTheme.Variant.allCases {
            let theme = "\(variant.isDark ? "dark" : "light")\(variant.increasesContrast ? " + increase contrast" : "")"
            func hex(_ token: Token) -> UInt32 { KeelTheme.value(token, in: variant).rgb }
            func pair(_ foreground: Token, _ background: Token, _ minimum: Double = 4.5) { check("\(theme) \(foreground) on \(background)", hex(foreground), hex(background), minimum) }

            for surface in Self.surfaces {
                pair(.fg, surface)
                // A selected segment's text is `fg`, so `muted` never sits on `segOn`.
                if surface != .segOn { pair(.muted, surface) }
            }
            for surface in Self.statusSurfaces { for token in [Token.accent, .success, .warning, .danger] { pair(token, surface) } }
            pair(.onAccent, .accent); pair(.onSaveBar, .saveBar); pair(.onProdStrip, .prodStrip)
            // FR-SF02: in dark the maroon sits on graphite by design and its text carries the meaning.
            if !variant.isDark { pair(.prodStrip, .tabBar, 3) }

            for type in KeyType.allCases {
                guard let badge = KeelTheme.badge(type) else { pair(.muted, .soft); continue }
                let (text, fill) = variant.isDark ? (badge.text.dark, badge.fill.dark) : (badge.text.light, badge.fill.light)
                check("\(theme) \(type) badge", text, fill, 4.5)
            }
            for (syntax, colors) in KeelTheme.syntax { check("\(theme) \(syntax) on codeBg", variant.isDark ? colors.dark : colors.light, hex(.codeBg), 4.5) }
            for color in LabelColor.allCases {
                guard let dot = KeelTheme.label(color).map({ variant.isDark ? $0.dark : $0.light }) else { continue }
                check("\(theme) \(color) label on sidebar", dot, hex(.sidebar), 3)
                check("\(theme) \(color) label on bg", dot, hex(.bg), 3)
            }
            if variant.increasesContrast { pair(.hair, .bg, 3); pair(.hairSoft, .bg, 3); pair(.sidebarHair, .sidebar, 3) }
        }

        // The console is the same in both themes (DS-05).
        func console(_ token: KeelTheme.Console) -> UInt32 { KeelTheme.console[token] ?? 0 }
        for token in [KeelTheme.Console.output, .command, .prompt, .hint, .notice, .null, .error] {
            check("console \(token)", console(token), console(.background), 4.5)
        }
        check("console command on list", console(.command), console(.list), 4.5)
        check("console command on listSelected", console(.command), console(.listSelected), 4.5)
        check("console cursor", console(.cursor), console(.background), 3)

        XCTAssertEqual(failures, [])
    }

    /// The ratio itself: WCAG 2's extremes and a pair the page quotes.
    func testContrastRatio() {
        XCTAssertEqual(KeelTheme.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(KeelTheme.contrast(0x777777, 0x777777), 1, accuracy: 0.0001)
        XCTAssertEqual(KeelTheme.contrast(0xFFFFFF, 0x7A1A14), KeelTheme.contrast(0x7A1A14, 0xFFFFFF), "order doesn't matter")
    }
}

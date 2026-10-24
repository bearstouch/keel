import AppKit
import KeelCore
import SwiftUI
import os

/// One 08 Design color: sRGB and its opacity (only `scrim` and `segShadow` are translucent).
struct Swatch: Equatable, Sendable {
    let rgb: UInt32
    let alpha: Double

    init(_ rgb: UInt32, alpha: Double = 1) { self.rgb = rgb; self.alpha = alpha }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// 08 Design → Color as data: the light and dark palettes, their Increase Contrast overrides, the console, badges,
/// JSON syntax and labels. `ThemeTokensTests` compares every value with the fixture generated from the page, and
/// `ThemeContrastTests` checks the page's contrast pairs, so nothing here drifts from the design (DS-06).
enum KeelTheme {
    typealias Pair = (light: UInt32, dark: UInt32)

    enum Token: String, CaseIterable, Sendable {
        case bg, sheet, sidebar, sidebarSelection, sidebarHair, tabBar, codeBg, field, soft, segBg, segOn, segShadow, card, track
        case hair, hairSoft, fg, muted, accent, onAccent, selection, changedRow, saveBar, onSaveBar, success, warning, danger
        case prodStrip, onProdStrip, scrim
    }

    /// The palette a color is drawn from: the window's light or dark appearance, each with or without Increase Contrast.
    struct Variant: Equatable, Sendable, CaseIterable {
        var isDark: Bool
        var increasesContrast: Bool

        static let light = Variant(isDark: false, increasesContrast: false)
        static let dark = Variant(isDark: true, increasesContrast: false)
        static let allCases = [light, dark, Variant(isDark: false, increasesContrast: true), Variant(isDark: true, increasesContrast: true)]

        /// AppKit reports Increase Contrast through the high-contrast appearance names only for the system appearance,
        /// and `NSAppearance(named:)` can't force them, so the system flag counts too (`KeelTheme.increasesContrast`).
        init(appearance: NSAppearance, increasesContrast flag: Bool) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            increasesContrast = flag || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        }

        init(isDark: Bool, increasesContrast: Bool) { self.isDark = isDark; self.increasesContrast = increasesContrast }
    }

    static let light: [Token: Swatch] = [
        .bg: Swatch(0xFFFFFF), .sheet: Swatch(0xFFFFFF), .sidebar: Swatch(0xFBEEEC), .sidebarSelection: Swatch(0xF4D2CD), .sidebarHair: Swatch(0xF1DAD7),
        .tabBar: Swatch(0xF6F8FB), .codeBg: Swatch(0xF6F8FB), .field: Swatch(0xF1F4F8), .soft: Swatch(0xF1F4F8), .segBg: Swatch(0xE7ECF2),
        .segOn: Swatch(0xFFFFFF), .segShadow: Swatch(0x18212F, alpha: 0.12), .card: Swatch(0xF4F7FA), .track: Swatch(0xDDE4EC),
        .hair: Swatch(0xE3E8EE), .hairSoft: Swatch(0xEEF2F6), .fg: Swatch(0x18212F), .muted: Swatch(0x4E5B6D), .accent: Swatch(0xC7302A),
        .onAccent: Swatch(0xFFFFFF), .selection: Swatch(0xFCEAE8), .changedRow: Swatch(0xFDF3F2), .saveBar: Swatch(0x18212F), .onSaveBar: Swatch(0xFFFFFF),
        .success: Swatch(0x216B3B), .warning: Swatch(0x805400), .danger: Swatch(0xB22D32), .prodStrip: Swatch(0x7A1A14), .onProdStrip: Swatch(0xFFFFFF),
        .scrim: Swatch(0x18212F, alpha: 0.22)
    ]

    static let dark: [Token: Swatch] = [
        .bg: Swatch(0x1E1E1E), .sheet: Swatch(0x2A2A2C), .sidebar: Swatch(0x29292B), .sidebarSelection: Swatch(0x3D2826), .sidebarHair: Swatch(0x333335),
        .tabBar: Swatch(0x29292B), .codeBg: Swatch(0x262628), .field: Swatch(0x38383A), .soft: Swatch(0x2C2C2E), .segBg: Swatch(0x38383A),
        .segOn: Swatch(0x48484A), .segShadow: Swatch(0x000000, alpha: 0), .card: Swatch(0x262628), .track: Swatch(0x48484A),
        .hair: Swatch(0x38383A), .hairSoft: Swatch(0x2C2C2E), .fg: Swatch(0xE5E5E7), .muted: Swatch(0xA1A1A6), .accent: Swatch(0xFF6F61),
        .onAccent: Swatch(0x2A0B08), .selection: Swatch(0x3D2826), .changedRow: Swatch(0x2E2423), .saveBar: Swatch(0xE5E5E7), .onSaveBar: Swatch(0x1E1E1E),
        .success: Swatch(0x8DDAA4), .warning: Swatch(0xF2CC7A), .danger: Swatch(0xFFA4A4), .prodStrip: Swatch(0x4A1F1C), .onProdStrip: Swatch(0xFFD6D1),
        .scrim: Swatch(0x05070A, alpha: 0.55)
    ]

    /// 08 Design → Increase Contrast: stronger secondary text and 3:1 hairlines; every other token keeps its value.
    static let increasedContrast: (light: [Token: Swatch], dark: [Token: Swatch]) = (
        [.muted: Swatch(0x364152), .hair: Swatch(0x7D8796), .hairSoft: Swatch(0x8A94A3), .sidebarHair: Swatch(0xA67A74)],
        [.muted: Swatch(0xC7C7CC), .hair: Swatch(0x7C7C80), .hairSoft: Swatch(0x6E6E73), .sidebarHair: Swatch(0x7C7C80)]
    )

    static func value(_ token: Token, in variant: Variant) -> Swatch {
        if variant.increasesContrast, let swatch = (variant.isDark ? increasedContrast.dark : increasedContrast.light)[token] { return swatch }
        // Both palettes list every token; `ThemeTokensTests` holds them to that.
        return (variant.isDark ? dark : light)[token] ?? Swatch(0xFF00FF)
    }

    /// The console's own palette, the same in both themes (DS-05).
    enum Console: String, CaseIterable, Sendable {
        case background, output, command, prompt, hint, notice, null, error, cursor, list, listSelected, listBorder
    }

    static let console: [Console: UInt32] = [
        .background: 0x151719, .output: 0xDEE0E5, .command: 0xFFFFFF, .prompt: 0x7C899C, .hint: 0x768297, .notice: 0x7C899C,
        .null: 0x8C95A3, .error: 0xFFA4A4, .cursor: 0xFF8A7E, .list: 0x2A2A2C, .listSelected: 0x3D2826, .listBorder: 0x3A3A3C
    ]

    /// Type badge text and fill; nil for `other` and a type not loaded yet, which use `muted` on `soft`.
    static func badge(_ type: KeyType) -> (text: Pair, fill: Pair)? {
        switch type {
        case .string: ((0x185AA8, 0x8BB8F0), (0xE3EDF9, 0x1E2B3E))
        case .hash: ((0x6B3FA0, 0xC6A0E8), (0xEFE7F8, 0x2A2238))
        case .list: ((0x0F6A6E, 0x7FD5DD), (0xDDF1F1, 0x163034))
        case .set: ((0x216B3B, 0x8DDAA4), (0xE2F2E7, 0x183025))
        case .zset: ((0x805400, 0xF2CC7A), (0xF8EDD8, 0x342B19))
        case .stream: ((0xA02D6A, 0xF5A3CF), (0xF8E4EF, 0x36202E))
        case .other, .unknown: nil
        }
    }

    /// JSON syntax in the value viewer.
    enum Syntax: String, CaseIterable, Sendable { case jsonKey, jsonString, jsonLiteral }

    static let syntax: [Syntax: Pair] = [.jsonKey: (0x185AA8, 0x8BB8F0), .jsonString: (0x216B3B, 0x8DDAA4), .jsonLiteral: (0x805400, 0xF2CC7A)]

    /// Label dots; `none` has no dot (the sheet draws an empty `muted` ring).
    static func label(_ color: LabelColor) -> Pair? {
        switch color {
        case .none: nil
        case .red: (0xC8363C, 0xFF7B7B)
        case .orange: (0xB86200, 0xF2A65A)
        case .yellow: (0x8A6D00, 0xF2D36B)
        case .green: (0x2E8B4F, 0x8DDAA4)
        case .blue: (0x2F6FBF, 0x8BB8F0)
        case .purple: (0x7B4FB0, 0xC6A0E8)
        case .gray: (0x7A8596, 0x8E8E93)
        }
    }

    /// Increase Contrast as macOS last reported it. Colors resolve while AppKit draws, off any actor, so the flag lives
    /// behind a lock; `SettingsModel` sets it at launch and on every accessibility display change.
    private static let contrastFlag = OSAllocatedUnfairLock(initialState: false)

    static var increasesContrast: Bool {
        get { contrastFlag.withLock { $0 } }
        set { contrastFlag.withLock { $0 = newValue } }
    }

    /// WCAG 2 contrast ratio of two sRGB colors (1…21).
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ value: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double(value >> shift & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The colors and fonts views use, built from `KeelTheme` (DS-06: nothing else). Every color follows the appearance
/// it is drawn in, so a theme change repaints without rebuilding a view (DS-11).
enum Tokens {
    static let bg = color(.bg)
    /// Sheets, Settings and the command palette: `bg` in light, a lifted graphite in dark.
    static let sheet = color(.sheet)
    /// The sidebar's soft Redis-red tint in light, graphite in dark; its edge and selected row.
    static let sidebar = color(.sidebar)
    static let sidebarSelection = color(.sidebarSelection)
    static let sidebarHair = color(.sidebarHair)
    static let field = color(.field)
    /// The key filter and db picker: like `field` in light, a step darker in dark (08 Design).
    static let soft = color(.soft)
    static let hair = color(.hair)
    /// Table rows (hash fields).
    static let hairSoft = color(.hairSoft)
    static let selection = color(.selection)
    /// A row with an unsaved edit.
    static let changedRow = color(.changedRow)
    /// The tab bar's strip under the toolbar.
    static let tabBar = color(.tabBar)
    /// The selected segment of the mode switch (on a `soft` track) and its lift: a soft shadow in light, none in dark.
    static let segOn = color(.segOn)
    static let segShadow = color(.segShadow)
    /// Info tiles and the memory bar's track (08 Design).
    static let card = color(.card)
    static let track = color(.track)
    /// The value viewer's panel and its view switch track (08 Design → Editor).
    static let codeBg = color(.codeBg)
    static let segBg = color(.segBg)
    /// The floating unsaved-changes bar and its text (08 Design → `saveBar`).
    static let saveBar = color(.saveBar)
    static let onSaveBar = color(.onSaveBar)
    static let fg = color(.fg)
    static let muted = color(.muted)
    static let accent = color(.accent)
    static let onAccent = color(.onAccent)
    static let success = color(.success)
    static let warning = color(.warning)
    static let danger = color(.danger)
    /// The production strip and its text (FR-SF02, DS-03): a deep maroon, deliberately apart from `accent`.
    static let prodStrip = color(.prodStrip)
    static let onProdStrip = color(.onProdStrip)
    static let scrim = color(.scrim)

    static func color(_ token: KeelTheme.Token) -> Color { Color(nsColor: NS.color(token)) }

    /// Label dots (08 Design → Type badges and labels). `none` has no dot; the sheet draws an empty ring.
    static func label(_ color: LabelColor) -> Color? { KeelTheme.label(color).map { Color(light: $0.light, dark: $0.dark) } }

    /// AppKit views' colors and fonts: the same tokens as `NSColor`, for cells drawn by AppKit.
    enum NS {
        static let bg = color(.bg)
        static let fg = color(.fg)
        static let muted = color(.muted)
        static let selection = color(.selection)
        static let soft = color(.soft)
        /// JSON syntax in the value viewer: keys, strings, and numbers / true / false / null.
        static let jsonKey = syntax(.jsonKey)
        static let jsonString = syntax(.jsonString)
        static let jsonLiteral = syntax(.jsonLiteral)

        /// A token resolved for the appearance it is drawn in, Increase Contrast included.
        static func color(_ token: KeelTheme.Token) -> NSColor {
            NSColor(name: nil) { appearance in
                KeelTheme.value(token, in: KeelTheme.Variant(appearance: appearance, increasesContrast: KeelTheme.increasesContrast)).nsColor
            }
        }

        private static func syntax(_ syntax: KeelTheme.Syntax) -> NSColor { NSColor(KeelTheme.syntax[syntax] ?? (0, 0)) }

        /// 08 Design → Type badges; `other` (and a type not loaded yet) is `muted` on `soft`.
        static func badge(_ type: KeyType) -> (fg: NSColor, fill: NSColor) {
            guard let badge = KeelTheme.badge(type) else { return (muted, soft) }
            return (NSColor(badge.text), NSColor(badge.fill))
        }

        /// Inter at the design's weight (Regular, Medium, SemiBold); the system font if the bundled face didn't load.
        static func interface(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            BundledFonts.register()
            return NSFont(name: BundledFonts.Face.interface(weight).rawValue, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }

        /// JetBrains Mono, Bold for 600 and up; the system monospace font if the bundled face didn't load.
        static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            BundledFonts.register()
            return NSFont(name: BundledFonts.Face.mono(weight).rawValue, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// SwiftUI falls back to the system font by itself when a face is missing (MAC-19).
    static func interface(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        BundledFonts.register()
        return .custom(BundledFonts.Face.interface(weight).rawValue, size: size)
    }

    static func mono(_ size: CGFloat = 12.5, weight: Font.Weight = .regular) -> Font {
        BundledFonts.register()
        return .custom(BundledFonts.Face.mono(weight).rawValue, size: size)
    }

    /// Every animation goes through here: none while Reduce Motion is on (DS-13, NFR-AX03).
    static func animation(_ animation: Animation, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension Color {
    /// A color that follows the window's appearance.
    init(light: UInt32, dark: UInt32) { self.init(nsColor: NSColor(light: light, dark: dark)) }
}

extension NSColor {
    /// A color that follows the appearance it is drawn in.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            Swatch(KeelTheme.Variant(appearance: appearance, increasesContrast: false).isDark ? dark : light).nsColor
        }
    }

    convenience init(_ pair: KeelTheme.Pair) { self.init(light: pair.light, dark: pair.dark) }
}

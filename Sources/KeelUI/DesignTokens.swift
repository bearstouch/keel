import AppKit
import KeelCore
import SwiftUI

/// The colors of 08 Design that the sheets and the sidebar use, light and dark (DS-06: nothing else). KEEL-044 completes the set and
/// bundles the fonts; until then `Font.custom` falls back to the system font.
enum Tokens {
    static let bg = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    /// Sheets are `bg` in light and `sheet` in dark.
    static let sheet = Color(light: 0xFFFFFF, dark: 0x2A2A2C)
    /// The sidebar's soft Redis-red tint in light, graphite in dark; its edge and selected row.
    static let sidebar = Color(light: 0xFBEEEC, dark: 0x29292B)
    static let sidebarSelection = Color(light: 0xF4D2CD, dark: 0x3D2826)
    static let sidebarHair = Color(light: 0xF1DAD7, dark: 0x333335)
    static let field = Color(light: 0xF1F4F8, dark: 0x38383A)
    /// The key filter and db picker: like `field` in light, a step darker in dark (08 Design).
    static let soft = Color(light: 0xF1F4F8, dark: 0x2C2C2E)
    static let hair = Color(light: 0xE3E8EE, dark: 0x38383A)
    /// The tab bar's strip under the toolbar.
    static let tabBar = Color(light: 0xF6F8FB, dark: 0x29292B)
    /// The selected segment of the mode switch (on a `soft` track).
    static let segOn = Color(light: 0xFFFFFF, dark: 0x48484A)
    /// The selected segment's lift: a soft shadow in light, none in dark.
    static let segShadow = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .clear : NSColor(srgbRed: 24 / 255, green: 33 / 255, blue: 47 / 255, alpha: 0.12) })
    /// The value viewer's panel and its view switch track (08 Design → Editor).
    static let codeBg = Color(light: 0xF6F8FB, dark: 0x262628)
    static let segBg = Color(light: 0xE7ECF2, dark: 0x38383A)
    /// The floating unsaved-changes bar and its text (08 Design → `saveBar`).
    static let saveBar = Color(light: 0x18212F, dark: 0xE5E5E7)
    static let onSaveBar = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let fg = Color(light: 0x18212F, dark: 0xE5E5E7)
    static let muted = Color(light: 0x4E5B6D, dark: 0xA1A1A6)
    static let accent = Color(light: 0xC7302A, dark: 0xFF6F61)
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x2A0B08)
    static let success = Color(light: 0x216B3B, dark: 0x8DDAA4)
    static let warning = Color(light: 0x805400, dark: 0xF2CC7A)
    static let danger = Color(light: 0xB22D32, dark: 0xFFA4A4)

    /// Label dots (08 Design → Type badges and labels). `none` has no dot; the sheet draws an empty ring.
    static func label(_ color: LabelColor) -> Color? {
        switch color {
        case .none: nil
        case .red: Color(light: 0xC8363C, dark: 0xFF7B7B)
        case .orange: Color(light: 0xB86200, dark: 0xF2A65A)
        case .yellow: Color(light: 0x8A6D00, dark: 0xF2D36B)
        case .green: Color(light: 0x2E8B4F, dark: 0x8DDAA4)
        case .blue: Color(light: 0x2F6FBF, dark: 0x8BB8F0)
        case .purple: Color(light: 0x7B4FB0, dark: 0xC6A0E8)
        case .gray: Color(light: 0x7A8596, dark: 0x8E8E93)
        }
    }

    /// The AppKit key list's colors and fonts: the same tokens as `NSColor`, for cells drawn by AppKit.
    enum NS {
        static let bg = NSColor(light: 0xFFFFFF, dark: 0x1E1E1E)
        static let fg = NSColor(light: 0x18212F, dark: 0xE5E5E7)
        static let muted = NSColor(light: 0x4E5B6D, dark: 0xA1A1A6)
        static let selection = NSColor(light: 0xFCEAE8, dark: 0x3D2826)
        static let soft = NSColor(light: 0xF1F4F8, dark: 0x2C2C2E)
        /// JSON syntax in the value viewer: keys, strings, and numbers / true / false / null.
        static let jsonKey = NSColor(light: 0x185AA8, dark: 0x8BB8F0)
        static let jsonString = NSColor(light: 0x216B3B, dark: 0x8DDAA4)
        static let jsonLiteral = NSColor(light: 0x805400, dark: 0xF2CC7A)

        /// 08 Design → Type badges; `other` (and a type not loaded yet) is `muted` on `soft`.
        static func badge(_ type: KeyType) -> (fg: NSColor, fill: NSColor) {
            switch type {
            case .string: (NSColor(light: 0x185AA8, dark: 0x8BB8F0), NSColor(light: 0xE3EDF9, dark: 0x1E2B3E))
            case .hash: (NSColor(light: 0x6B3FA0, dark: 0xC6A0E8), NSColor(light: 0xEFE7F8, dark: 0x2A2238))
            case .list: (NSColor(light: 0x0F6A6E, dark: 0x7FD5DD), NSColor(light: 0xDDF1F1, dark: 0x163034))
            case .set: (NSColor(light: 0x216B3B, dark: 0x8DDAA4), NSColor(light: 0xE2F2E7, dark: 0x183025))
            case .zset: (NSColor(light: 0x805400, dark: 0xF2CC7A), NSColor(light: 0xF8EDD8, dark: 0x342B19))
            case .stream: (NSColor(light: 0xA02D6A, dark: 0xF5A3CF), NSColor(light: 0xF8E4EF, dark: 0x36202E))
            case .other, .unknown: (muted, soft)
            }
        }

        /// Inter is matched by name, so a weight can only be reached through its bold face; the system font is the fallback.
        static func interface(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            NSFont(name: "Inter", size: size).map { NSFontManager.shared.convert($0, toHaveTrait: weight >= .semibold ? .boldFontMask : []) }
                ?? .systemFont(ofSize: size, weight: weight)
        }

        static func mono(_ size: CGFloat) -> NSFont { NSFont(name: "JetBrains Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }
    }

    static func interface(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .custom("Inter", size: size).weight(weight) }
    static func mono(_ size: CGFloat = 12.5) -> Font { .custom("JetBrains Mono", size: size) }
}

extension Color {
    /// A color that follows the window's appearance.
    init(light: UInt32, dark: UInt32) { self.init(nsColor: NSColor(light: light, dark: dark)) }
}

extension NSColor {
    /// A color that follows the appearance it is drawn in.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}

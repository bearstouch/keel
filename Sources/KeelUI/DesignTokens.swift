import AppKit
import KeelCore
import SwiftUI

/// The colors of 08 Design that the sheets use, light and dark (DS-06: nothing else). KEEL-049 completes the set and
/// bundles the fonts; until then `Font.custom` falls back to the system font.
enum Tokens {
    static let bg = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    /// Sheets are `bg` in light and `sheet` in dark.
    static let sheet = Color(light: 0xFFFFFF, dark: 0x2A2A2C)
    static let field = Color(light: 0xF1F4F8, dark: 0x38383A)
    static let hair = Color(light: 0xE3E8EE, dark: 0x38383A)
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

    static func interface(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .custom("Inter", size: size).weight(weight) }
    static func mono(_ size: CGFloat = 12.5) -> Font { .custom("JetBrains Mono", size: size) }
}

extension Color {
    /// A color that follows the window's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            })
    }
}

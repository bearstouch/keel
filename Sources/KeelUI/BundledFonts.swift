import AppKit
import CoreText
import SwiftUI

/// Inter and JetBrains Mono, shipped in KeelUI's resource bundle and registered for the Keel process only (MAC-19):
/// nothing is installed for the user, and a face that fails to load leaves its role on the system font.
public enum BundledFonts {
    /// Each bundled face by its PostScript name, which is also its file name in `Resources/Fonts`.
    public enum Face: String, CaseIterable, Sendable {
        case interRegular = "Inter-Regular", interMedium = "Inter-Medium", interSemiBold = "Inter-SemiBold"
        case monoRegular = "JetBrainsMono-Regular", monoBold = "JetBrainsMono-Bold"
        case monoItalic = "JetBrainsMono-Italic", monoBoldItalic = "JetBrainsMono-BoldItalic"

        /// 08 Design → Typography uses 400, 500 and 600; anything heavier takes SemiBold, the heaviest face shipped.
        static func interface(_ weight: NSFont.Weight) -> Face {
            if weight >= .semibold { return .interSemiBold }
            return weight >= .medium ? .interMedium : .interRegular
        }

        static func interface(_ weight: Font.Weight) -> Face {
            switch weight {
            case .medium: .interMedium
            case .semibold, .bold, .heavy, .black: .interSemiBold
            default: .interRegular
            }
        }

        /// The editor's key title is mono 600, drawn with Bold.
        static func mono(_ weight: NSFont.Weight) -> Face { weight >= .semibold ? .monoBold : .monoRegular }

        static func mono(_ weight: Font.Weight) -> Face {
            switch weight {
            case .semibold, .bold, .heavy, .black: .monoBold
            default: .monoRegular
            }
        }

        public var url: URL? { Bundle.module.url(forResource: rawValue, withExtension: "ttf", subdirectory: "Fonts") }
    }

    /// Registers every face once per process (a Swift `static let` runs its initializer exactly once, on first use) and
    /// returns the faces now available. Registration is synchronous, per file: the batch API registers asynchronously,
    /// so the first window would otherwise resolve the fallback.
    @discardableResult
    public static func register() -> Set<Face> { registered }

    private static let registered: Set<Face> = {
        var available = Set<Face>()
        for face in Face.allCases {
            guard let url = face.url else { continue }
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // Already registered (by a previous test host in this process, say) counts as available.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            if ok || code == CTFontManagerError.alreadyRegistered.rawValue { available.insert(face) }
        }
        return available
    }()
}

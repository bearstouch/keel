import AppKit
import CoreText
import SwiftUI
import XCTest

@testable import KeelUI

/// KEEL-044 AC2, MAC-19: Inter and JetBrains Mono ship in the bundle and are registered for this process only.
final class BundledFontsTests: XCTestCase {
    func testFontsRegisterForProcess() throws {
        XCTAssertEqual(BundledFonts.register(), Set(BundledFonts.Face.allCases))
        XCTAssertEqual(BundledFonts.register(), Set(BundledFonts.Face.allCases), "registering again is harmless")
        for face in BundledFonts.Face.allCases {
            let url = try XCTUnwrap(face.url, "\(face.rawValue).ttf is in the bundle")
            // Process scope: nothing is installed for the user or the session.
            XCTAssertEqual(CTFontManagerGetScopeForURL(url as CFURL), .process, face.rawValue)
            let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            XCTAssertEqual(names, [face.rawValue], "the file holds the face its name promises")
            XCTAssertEqual(NSFont(name: face.rawValue, size: 13)?.fontName, face.rawValue)
        }
    }

    /// Chrome text is Inter at the design's weights; keys, values and the console are JetBrains Mono.
    func testTokensUseBundledFaces() {
        XCTAssertEqual(Tokens.NS.interface(13).fontName, "Inter-Regular")
        XCTAssertEqual(Tokens.NS.interface(13, weight: .medium).fontName, "Inter-Medium")
        XCTAssertEqual(Tokens.NS.interface(13, weight: .semibold).fontName, "Inter-SemiBold")
        XCTAssertEqual(Tokens.NS.interface(13, weight: .bold).fontName, "Inter-SemiBold", "the heaviest face shipped")
        XCTAssertEqual(Tokens.NS.mono(12.5).fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(Tokens.NS.mono(20, weight: .semibold).fontName, "JetBrainsMono-Bold")
        XCTAssertEqual(ConsoleTheme.font.fontName, "JetBrainsMono-Regular")
        XCTAssertEqual(ConsoleTheme.font.pointSize, 14)
        XCTAssertEqual(BundledFonts.Face.interface(Font.Weight.regular), .interRegular)
        XCTAssertEqual(BundledFonts.Face.interface(Font.Weight.medium), .interMedium)
        XCTAssertEqual(BundledFonts.Face.interface(Font.Weight.semibold), .interSemiBold)
        XCTAssertEqual(BundledFonts.Face.mono(Font.Weight.semibold), .monoBold)
        XCTAssertEqual(BundledFonts.Face.mono(Font.Weight.regular), .monoRegular)
    }
}

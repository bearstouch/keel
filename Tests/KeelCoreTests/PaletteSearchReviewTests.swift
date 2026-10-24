import Foundation
import XCTest

@testable import KeelCore

final class PaletteSearchReviewTests: XCTestCase {
    /// Foundation's substring search can match at the start of a name where `hasPrefix` (whole grapheme clusters)
    /// doesn't; scoring must not step before the first character.
    func testMatchAtStartInsideGraphemeClusterDoesNotCrash() {
        for name in ["👨‍👩‍👧-prod", "🇵🇹 payments", "e\u{301}cole"] {
            for query in ["👨", "🇵", "e", "\u{301}"] { _ = PaletteSearch.rank([PaletteItem(id: name, kind: .connection, title: name)], query: query) }
        }
    }
}

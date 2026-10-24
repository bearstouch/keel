import Foundation
import XCTest

@testable import KeelCore

final class PaletteSearchTests: XCTestCase {
    private static func connection(_ name: String, _ subtitle: String = "") -> PaletteItem { PaletteItem(id: "connection:\(name)", kind: .connection, title: name, subtitle: subtitle) }

    func testFuzzyRanking() {
        let items = [
            Self.connection("payments-staging", "Production"), Self.connection("payments-prod-replica"), Self.connection("orders-prod"),
            Self.connection("payments-prod"), PaletteItem(id: "command:refresh", kind: .action, title: "Refresh", subtitle: "View", shortcut: "⌘R")
        ]
        // AC1: words in any order; "payments-prod" first, the longer name after; a folder named "Production" matches only
        // through its subtitle, so it ranks last; "orders-prod" has no "pay" and is out.
        XCTAssertEqual(PaletteSearch.rank(items, query: "prod pay").map(\.title), ["payments-prod", "payments-prod-replica", "payments-staging"])
        // A word start outranks the same letters inside a word, which outranks letters in order.
        let words = [Self.connection("cache-orders"), Self.connection("preorders"), Self.connection("o-r-d-e-r-s")]
        XCTAssertEqual(PaletteSearch.rank(words, query: "orders").map(\.title), ["cache-orders", "preorders", "o-r-d-e-r-s"])
        // Letters in order still match; fewer gaps rank higher.
        XCTAssertEqual(PaletteSearch.rank(words, query: "ordrs").map(\.title).last, "o-r-d-e-r-s")
        XCTAssertEqual(PaletteSearch.rank(words, query: "ordrs").count, 3)
        // Case and diacritics are ignored; every word must match.
        XCTAssertEqual(PaletteSearch.rank([Self.connection("Café-Prod")], query: "cafe PROD").count, 1)
        XCTAssertEqual(PaletteSearch.rank(items, query: "prod zzz"), [])
        // A connection and a command matching equally: the connection comes first.
        let tie = [PaletteItem(id: "command:x", kind: .action, title: "Disconnect"), PaletteItem(id: "connection:x", kind: .connection, title: "Disconnect")]
        XCTAssertEqual(PaletteSearch.rank(tie, query: "disc").map(\.kind), [.connection, .action])
        // No query: everything, grouped by kind in the sources' order, and never more than the limit.
        XCTAssertEqual(PaletteSearch.rank(items, query: "  ").first?.title, "payments-staging")
        XCTAssertEqual(PaletteSearch.rank(items, query: " ").last?.kind, .action)
        let many = (0..<200).map { Self.connection("db-\($0)") }
        XCTAssertEqual(PaletteSearch.rank(many, query: "db").count, PaletteSearch.limit)
    }

    func testRecentKeysAreMemoryOnly() {
        // Key names from browsing are never persisted (02 → Persistence): the type can't even be encoded.
        XCTAssertFalse((RecentKeys() as Any) is any Encodable)
        XCTAssertFalse((RecentKeys.Entry(profileID: UUID(), database: 0, key: Data()) as Any) is any Encodable)

        let profile = UUID(), other = UUID()
        var recent = RecentKeys()
        for index in 0..<(RecentKeys.limit + 5) { recent.record(.init(profileID: profile, database: 0, key: Data("user:\(index)".utf8))) }
        XCTAssertEqual(recent.entries.count, RecentKeys.limit, "Bounded")
        XCTAssertEqual(recent.entries.first?.key, Data("user:\(RecentKeys.limit + 4)".utf8), "Newest first")
        // Reopening moves the key to the front instead of listing it twice; the same name in another db is another key.
        let reopened = RecentKeys.Entry(profileID: profile, database: 0, key: Data("user:10".utf8))
        recent.record(reopened)
        recent.record(.init(profileID: other, database: 3, key: Data("user:10".utf8)))
        XCTAssertEqual(recent.entries.count, RecentKeys.limit)
        XCTAssertEqual(recent.entries.filter { $0.key == reopened.key }.count, 2)
        XCTAssertEqual(recent.entries[1], reopened)
        // Bytes are kept exactly, and a huge name isn't kept at all.
        recent.record(.init(profileID: other, database: 0, key: Data([0x00, 0xFF, 0x0A])))
        XCTAssertEqual(recent.entries.first?.key, Data([0x00, 0xFF, 0x0A]))
        recent.record(.init(profileID: other, database: 0, key: Data(count: 4_096)))
        XCTAssertNotEqual(recent.entries.first?.key.count, 4_096)
        // A deleted profile's keys go; a new run starts empty.
        recent.forget(profileID: other)
        XCTAssertTrue(recent.entries.allSatisfy { $0.profileID == profile })
        XCTAssertEqual(RecentKeys().entries, [])
    }
}

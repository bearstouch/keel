import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review-driven sorted set editor cases (KEEL-033).
final class SortedSetEditorReviewTests: XCTestCase {
    private let key = Data("z".utf8)
    private let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))

    private func d(_ text: String) -> Data { Data(text.utf8) }

    /// Highest first pages through ties with `REV` / `ZREVRANGEBYSCORE` skips: every member once, in Redis's reverse order.
    func testDescendingTiesPageWithoutGapsOrRepeats() async throws {
        for byScore in [true, false] {
            let server = SortedSetServer((0..<1_200).map { (String(format: "m%04d", $0), $0 < 100 ? 0 : 1) }, byScore: byScore)
            let service = server.service()
            let first = try await SortedSetEditor.load(key: key, descending: true, service: service, context: context)
            var all = first.rows, cursor = first.next
            while let next = cursor {
                let page = try await SortedSetEditor.loadMore(key: key, cursor: next, service: service, context: context)
                all += page.rows; cursor = page.next
            }
            XCTAssertEqual(all.count, 1_200, "byScore \(byScore)")
            XCTAssertEqual(Set(all.map(\.id)).count, 1_200, "byScore \(byScore)")
            XCTAssertEqual(all.map(\.id), (0..<1_200).reversed().map { d(String(format: "m%04d", $0)) }, "byScore \(byScore)")
        }
    }

    /// Members at `+inf` page from an inclusive `+inf` bound, skipping the ones loaded.
    func testInfiniteScoresPage() async throws {
        let server = SortedSetServer((0..<700).map { ("m\($0)", Double.infinity) } + [("low", 1)])
        let service = server.service()
        let first = try await SortedSetEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(first.next.flatMap(SortedSetEditor.Cursor.init), SortedSetEditor.Cursor(descending: false, score: .infinity, skip: 499))
        let second = try await SortedSetEditor.loadMore(key: key, cursor: try XCTUnwrap(first.next), service: service, context: context)
        XCTAssertEqual(server.keyCommands.last, ["ZRANGE", "z", "+inf", "+inf", "BYSCORE", "WITHSCORES", "LIMIT", "499", "500"])
        XCTAssertNil(second.next)
        XCTAssertEqual(Set((first.rows + second.rows).map(\.id)).count, 701)
    }

    /// A RESP2 score matches the RESP3 double a guard expects by value, `inf` included; any other value doesn't.
    func testGuardScoreEquivalence() {
        XCTAssertTrue(DataCommandService.sameScore(.bulkString(d("0.10000000000000001")), .double(0.1)))
        XCTAssertTrue(DataCommandService.sameScore(.bulkString(d("inf")), .double(.infinity)))
        XCTAssertTrue(DataCommandService.sameScore(.bulkString(d("-inf")), .double(-.infinity)))
        XCTAssertFalse(DataCommandService.sameScore(.bulkString(d("0.2")), .double(0.1)))
        XCTAssertFalse(DataCommandService.sameScore(.bulkString(d("0.1")), .bulkString(d("0.1"))), "only a double expectation")
        XCTAssertFalse(DataCommandService.sameScore(.null, .double(0.1)))
    }

    /// FR-ED05: input takes decimal numbers and `inf` / `+inf` / `-inf` in any case. A literal too large or too small
    /// for a double is refused instead of saving `inf` or 0, and NaN, hex floats and other spellings are refused.
    func testParseScoreRefusesOverflowAndOtherSpellings() {
        for (text, score) in [("inf", Double.infinity), ("+INF", .infinity), ("-Inf", -.infinity), (".5", 0.5), ("5.", 5), ("-0", -0.0), ("0.000", 0), ("1e308", 1e308), ("5e-324", 5e-324)] {
            XCTAssertEqual(SortedSetEditor.parseScore(text), score, text)
        }
        for invalid in ["1e400", "-1e400", "1e-400", "infinity", "-Infinity", "nan", "-nan", "0x10", "0x1p3", ".", "e5", "1e", "1e+", "+", "1 2", "١"] {
            XCTAssertNil(SortedSetEditor.parseScore(invalid), invalid)
        }
    }
}

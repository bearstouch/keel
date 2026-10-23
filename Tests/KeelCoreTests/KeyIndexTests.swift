import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A fake keyspace served by `SCAN`: cursor `n` returns page `n` and points at `n + 1`; the last page returns cursor 0.
final class ScanServer: @unchecked Sendable {
    let server: RecordingServer

    init(pages: [[String]], fail: @escaping @Sendable (_ cursor: Int) -> String? = { _ in nil }) {
        server = RecordingServer { arguments in
            guard arguments.first?.uppercased() == "SCAN", let cursor = Int(arguments[1]), pages.indices.contains(cursor) else { return "-ERR unexpected\r\n" }
            if let error = fail(cursor) { return error }
            let next = cursor + 1 == pages.count ? 0 : cursor + 1
            return ScanServer.reply(cursor: next, keys: pages[cursor])
        }
    }

    static func reply(cursor: Int, keys: [String]) -> String {
        let cursorText = String(cursor)
        return "*2\r\n$\(cursorText.utf8.count)\r\n\(cursorText)\r\n*\(keys.count)\r\n" + keys.map { "$\($0.utf8.count)\r\n\($0)\r\n" }.joined()
    }

    var scans: [[String]] { server.allCommands }

    func index(_ configuration: KeyIndexConfiguration = KeyIndexConfiguration(), readOnly: Bool = true) -> KeyIndex {
        let context = DataContext(profile: SafetyProfile(name: "payments-prod", readOnly: readOnly))
        return KeyIndex(service: DataCommandService(session: server.session()), context: context, configuration: configuration)
    }
}

func keys(_ prefix: String, _ range: Range<Int>) -> [String] { range.map { "\(prefix):\($0)" } }

final class KeyIndexTests: XCTestCase {
    // MARK: - Story tests

    func testNeverSendsKeys() async {
        let fake = ScanServer(pages: [keys("user", 0..<10), keys("user", 10..<20), keys("order", 0..<5)])
        let index = fake.index(KeyIndexConfiguration(match: Data("user:*".utf8)))
        await index.autoPage()
        await index.restart(match: nil, type: Data("hash".utf8))
        await index.loadMore()
        await index.loadMore()

        XCTAssertFalse(fake.scans.isEmpty)
        XCTAssertTrue(fake.scans.allSatisfy { $0.first == "SCAN" }, "\(fake.scans)")
        XCTAssertFalse(fake.scans.contains { $0.contains { $0.uppercased() == "KEYS" } })
        // Every connection the browser opened is its own role on the profile's database.
        XCTAssertEqual(fake.server.opened.map(\.role), [.browser(database: 0)])
        XCTAssertEqual(fake.scans.first, ["SCAN", "0", "MATCH", "user:*", "COUNT", "1000"])
        XCTAssertEqual(fake.scans[3], ["SCAN", "0", "COUNT", "1000", "TYPE", "hash"])
    }

    func testLoadMoreIssuesOneScan() async {
        let fake = ScanServer(pages: [keys("a", 0..<3), keys("a", 3..<6), keys("a", 6..<9)])
        let index = fake.index()

        var status = await index.loadMore()
        XCTAssertEqual(fake.scans.count, 1)
        XCTAssertEqual(status.loadedCount, 3)
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(KeyIndexFooter(status: status, totalKeys: 9).text, "3 of 9 keys loaded · Load more")

        status = await index.loadMore()
        XCTAssertEqual(fake.scans.count, 2)
        XCTAssertEqual(fake.scans[1][1], "1", "the second click continues from the returned cursor")
        XCTAssertEqual(status.loadedCount, 6)
        let loaded = await index.keys(in: 0..<100)
        XCTAssertEqual(loaded, keys("a", 0..<6).map { Data($0.utf8) })
    }

    func testAutoPageStopsAtLimit() async {
        let fake = ScanServer(pages: (0..<10).map { keys("k", $0 * 10..<$0 * 10 + 10) })
        let index = fake.index(KeyIndexConfiguration(pageSize: 10, limit: 25))

        var status = await index.autoPage()
        XCTAssertEqual(status.phase, .limitReached)
        XCTAssertEqual(status.loadedCount, 25, "the limit is exact; the rest of the page is held back")
        XCTAssertEqual(fake.scans.count, 3, "no SCAN after the limit")
        XCTAssertTrue(status.canContinue)
        XCTAssertEqual(KeyIndexFooter(status: status, totalKeys: 100).text, "25 of 100 keys loaded · Limit reached · Continue")

        // Auto-paging again at the limit sends nothing.
        status = await index.autoPage()
        XCTAssertEqual(fake.scans.count, 3)

        // Continue raises the limit by another 25 and keeps auto-paging; the held-back keys come first, none lost.
        status = await index.continueScanning()
        XCTAssertEqual(status.loadedCount, 50)
        XCTAssertEqual(status.limit, 50)
        XCTAssertEqual(status.phase, .limitReached)
        let loaded = await index.keys(in: 0..<50)
        XCTAssertEqual(loaded, keys("k", 0..<50).map { Data($0.utf8) })
    }

    func testDeduplicatesScanResults() async {
        // SCAN may return a key again (rehashing); `a:1` and `a:3` repeat across pages and within a page.
        let fake = ScanServer(pages: [["a:1", "a:2", "a:1"], ["a:3", "a:2"], ["a:3", "a:4", "a:1"]])
        let index = fake.index()
        let status = await index.autoPage()

        XCTAssertEqual(status.loadedCount, 4)
        let loaded = await index.keys(in: 0..<10)
        XCTAssertEqual(loaded, ["a:1", "a:2", "a:3", "a:4"].map { Data($0.utf8) })
    }

    func testCursorZeroMarksComplete() async {
        let fake = ScanServer(pages: [keys("a", 0..<2), keys("a", 2..<4)])
        let index = fake.index()

        var status = await index.loadMore()
        XCTAssertEqual(status.phase, .idle)
        status = await index.loadMore()
        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(KeyIndexFooter(status: status, totalKeys: 4).text, "All keys loaded")
        XCTAssertNil(KeyIndexFooter(status: status).action)

        // Nothing more is sent once the cursor came back to 0.
        status = await index.loadMore()
        status = await index.autoPage()
        XCTAssertEqual(fake.scans.count, 2)
        XCTAssertEqual(status.loadedCount, 4)
    }

    // MARK: - Failure safety and footer

    func testFailedPageKeepsKeysAndRetriesSameCursor() async {
        let failures = FailOnce()
        let fake = ScanServer(pages: [keys("a", 0..<3), keys("a", 3..<6)]) { cursor in cursor == 1 && failures.take() ? "-ERR busy loading\r\n" : nil }
        let index = fake.index()
        await index.loadMore()
        var status = await index.autoPage()
        XCTAssertEqual(status.phase, .failed(KeyIndexError(code: "SERVER_ERROR", message: "ERR busy loading")))
        XCTAssertEqual(status.loadedCount, 3, "previous keys retained")
        XCTAssertEqual(KeyIndexFooter(status: status).action, .retry)

        status = await index.loadMore()
        XCTAssertEqual(fake.scans.map { $0[1] }, ["0", "1", "1"], "the retry resends the same cursor")
        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(status.loadedCount, 6)
    }

    func testMalformedReplyFailsWithoutChangingState() {
        XCTAssertEqual(try? KeyIndex.parse(.array([.bulkString(Data("0".utf8)), .set([.bulkString(Data("k".utf8))])])).get().keys, [Data("k".utf8)])
        for reply: RESPValue in [.simpleString(Data("OK".utf8)), .array([.bulkString(Data("x".utf8)), .array([])]), .array([.bulkString(Data("0".utf8)), .array([.integer(1)])])] {
            guard case .failure(let error) = KeyIndex.parse(reply) else { return XCTFail("\(reply) should be refused") }
            XCTAssertEqual(error.code, "PROTOCOL_ERROR")
        }
        guard case .failure(let error) = KeyIndex.parse(.error(Data("NOPERM this user has no permissions".utf8))) else { return XCTFail() }
        XCTAssertEqual(error.code, "PERMISSION_DENIED")
    }

    func testPauseStopsAutoPagingAfterThePageInFlight() async {
        let fake = ScanServer(pages: (0..<5).map { keys("p", $0 * 2..<$0 * 2 + 2) })
        let index = fake.index()
        await index.loadMore()
        await index.pause()
        var status = await index.status
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(KeyIndexFooter(status: status).text, "2 keys loaded · Paused · Load more")
        status = await index.loadMore()
        XCTAssertEqual(status.loadedCount, 4, "Load more resumes one page at a time")
        XCTAssertEqual(fake.scans.count, 2)
    }

    func testRestartClearsKeysAndStartsFromCursorZero() async {
        let fake = ScanServer(pages: [keys("a", 0..<3), keys("a", 3..<6)])
        let index = fake.index()
        await index.autoPage()
        await index.restart()
        var status = await index.status
        XCTAssertEqual(status.loadedCount, 0)
        XCTAssertEqual(status.phase, .idle)
        status = await index.loadMore()
        XCTAssertEqual(fake.scans.last?[1], "0")
        XCTAssertEqual(status.loadedCount, 3)
    }

    func testContinueStopsAtTheHardMaximum() {
        let status = KeyIndexStatus(loadedCount: 10_000_000, limit: KeyIndexConfiguration.maximumLimit, phase: .limitReached, mode: .auto)
        XCTAssertFalse(status.canContinue)
        XCTAssertEqual(KeyIndexFooter(status: status, totalKeys: 12_400_000).text, "10,000,000 of 12.4M keys loaded · Limit reached")
        XCTAssertEqual(KeyIndexConfiguration(limit: 50_000_000).limit, KeyIndexConfiguration.maximumLimit)
    }

    func testFooterMatchesTheSpecExamples() {
        let status = KeyIndexStatus(loadedCount: 250_000, limit: 1_000_000, phase: .idle, mode: .manual)
        XCTAssertEqual(KeyIndexFooter(status: status, totalKeys: 1_234_567).text, "250,000 of 1.2M keys loaded · Load more")
        XCTAssertEqual(KeyIndexFooter.abbreviated(1_999_999), "1.9M")
        XCTAssertEqual(KeyIndexFooter.abbreviated(3_000_000), "3M")
        XCTAssertEqual(KeyIndexFooter.abbreviated(2_500_000_000), "2.5B")
        XCTAssertEqual(KeyIndexFooter.abbreviated(999_999), "999,999")
        XCTAssertEqual(KeyIndexFooter.grouped(7), "7")
        var scanning = status
        scanning.phase = .scanning
        XCTAssertEqual(KeyIndexFooter(status: scanning, totalKeys: 1_234_567).text, "250,000 of 1.2M keys loaded")
    }
}

/// True exactly once, for a fake that fails one SCAN.
final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.withLock {
            defer { used = true }; return !used
        }
    }
}

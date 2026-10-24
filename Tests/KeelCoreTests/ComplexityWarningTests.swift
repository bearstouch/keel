import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// O(N) warnings for the console (FR-SF08): the size is read first, and only sizes above 10,000 warn.
final class ComplexityWarningTests: XCTestCase {
    private let context = DataContext(profile: SafetyProfile(name: "api-staging", readOnly: false), consoleID: UUID())

    /// Sizes per command: `SCARD big` 25,000, `HLEN small` 12, `LLEN list` 30,000, `DBSIZE` 1,000,000.
    private func server(dbsize: Int = 1_000_000, keyspace: String = "db0:keys=8000,expires=0,avg_ttl=0\r\ndb3:keys=4000,expires=0,avg_ttl=0") -> RecordingServer {
        RecordingServer { arguments in
            switch (arguments.first, arguments.count > 1 ? arguments[1] : "") {
            case ("SCARD", "big"): return ":25000\r\n"
            case ("SCARD", _), ("HLEN", _): return ":12\r\n"
            case ("LLEN", "list"): return ":30000\r\n"
            case ("DBSIZE", _): return ":\(dbsize)\r\n"
            case ("INFO", _):
                let text = "# Keyspace\r\n\(keyspace)\r\n"
                return "$\(text.utf8.count)\r\n\(text)\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
    }

    private func check(_ line: String, _ server: RecordingServer) async -> ComplexityWarning? {
        await ComplexityWarning.check(line.split(separator: " ").map { Data($0.utf8) }, service: DataCommandService(session: server.session()), context: context)
    }

    // MARK: - Story tests

    func testWarnsOnLargeKeys() async {
        let fake = server()
        // A 25,000-member set warns with its size; a 12-field hash doesn't.
        let large = await check("SMEMBERS big", fake)
        XCTAssertEqual(large?.kind, .wholeValue(command: "SMEMBERS", elements: 25_000))
        XCTAssertEqual(large?.message.contains("25,000"), true)
        XCTAssertFalse(large?.message.contains("big") ?? true, "the warning never names the key")
        let small = await check("HGETALL small", fake)
        XCTAssertNil(small)
        // The size is read before anything else is sent: only the length commands went out, never SMEMBERS / HGETALL.
        XCTAssertEqual(fake.allCommands.map { $0.first ?? "" }, ["SCARD", "HLEN"])
        // The reads ran on the console's own connection.
        XCTAssertTrue(fake.opened.allSatisfy { if case .console = $0.role { true } else { false } })
    }

    // MARK: - Other O(N) commands

    func testKeysWarnsWithDatabaseSize() async {
        let warning = await check("KEYS *", server())
        XCTAssertEqual(warning?.kind, .keys(databaseSize: 1_000_000))
        XCTAssertEqual(warning?.message.contains("1,000,000"), true)
        let smallDatabase = await check("KEYS *", server(dbsize: 50))
        XCTAssertNil(smallDatabase)
    }

    func testLrangeWarnsOnTheSpanItReads() async {
        let fake = server()
        let whole = await check("LRANGE list 0 -1", fake)
        XCTAssertEqual(whole?.kind, .wholeValue(command: "LRANGE", elements: 30_000))
        // A page of 100 is cheap whatever the list's length.
        let page = await check("LRANGE list 0 99", fake)
        XCTAssertNil(page)
        XCTAssertEqual(ComplexityWarning.span(start: -5, stop: -1, length: 30_000), 5)
        XCTAssertEqual(ComplexityWarning.span(start: 10, stop: 5, length: 30_000), 0)
        XCTAssertEqual(ComplexityWarning.span(start: 0, stop: 1_000_000, length: 30_000), 30_000)
        XCTAssertEqual(ComplexityWarning.span(start: -100_000, stop: -1, length: 30_000), 30_000)
    }

    func testFlushAllWithoutAsyncWarnsWithTheTotal() async {
        let warning = await check("FLUSHALL", server(keyspace: "db0:keys=8000,expires=0,avg_ttl=0\r\ndb3:keys=4000,expires=0,avg_ttl=0"))
        XCTAssertEqual(warning?.kind, .flushAllSync(keys: 12_000))
        let sync = await check("FLUSHALL SYNC", server())
        XCTAssertEqual(sync?.kind, .flushAllSync(keys: 12_000))
        // ASYNC frees in the background: no warning and nothing measured.
        let fake = server()
        let async = await check("flushall async", fake)
        XCTAssertNil(async)
        XCTAssertTrue(fake.allCommands.isEmpty)
    }

    func testCheapOrUnreadableCommandsDoNotWarn() async {
        let fake = server()
        for line in ["GET k", "SSCAN big 0", "LRANGE list zero -1", "SMEMBERS"] {
            let warning = await check(line, fake)
            XCTAssertNil(warning, line)
        }
        XCTAssertTrue(fake.allCommands.isEmpty)
        // A size the server won't give (an error) doesn't warn; the policy's own confirmations still apply.
        let failing = RecordingServer { _ in "-NOPERM no permissions\r\n" }
        let unknown = await check("SMEMBERS big", failing)
        XCTAssertNil(unknown)
    }
}

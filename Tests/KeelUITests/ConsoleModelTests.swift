import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The console model over the data path (KEEL-041): masked echo and history, the view's text, clearing, shared history.
@MainActor
final class ConsoleModelTests: XCTestCase {
    private func model(_ keyspace: TransactionalKeyspace, histories: ConsoleHistoryBook = ConsoleHistoryBook(), profileID: UUID = UUID()) -> ConsoleModel {
        let server = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: TransactionalKeyspace.Transport(keyspace))
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "") }
            return connection
        }
        let profile = SafetyProfile(name: "local-dev", readOnly: false, server: "127.0.0.1:6379")
        let console = ConsoleSession(service: DataCommandService(session: server), profile: profile, database: 0)
        return ConsoleModel(console: console, profileID: profileID, histories: histories, prompt: "127.0.0.1:6379> ")
    }

    func testAuthIsMaskedInEchoHistoryAndView() async {
        let keyspace = TransactionalKeyspace(["k": "v"])
        let histories = ConsoleHistoryBook(), profileID = UUID()
        let console = model(keyspace, histories: histories, profileID: profileID)
        _ = console.scrollView
        await console.submit("AUTH secret")
        await console.submit("GET k")

        XCTAssertEqual(console.buffer.lines.first, ConsoleLine("AUTH ••••••", kind: .command(prompt: "127.0.0.1:6379> ")))
        XCTAssertEqual(console.history.entries, ["AUTH ••••••", "GET k"])
        // The secret was sent as typed, and only the masked line is on screen.
        XCTAssertEqual(keyspace.commands.first, ["AUTH", "secret"])
        let text = console.textView?.string ?? ""
        XCTAssertTrue(text.contains("AUTH ••••••"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("\"v\""))
        XCTAssertTrue(text.hasSuffix("127.0.0.1:6379> "))

        // History belongs to the profile: another console of it sees the same entries.
        XCTAssertEqual(model(keyspace, histories: histories, profileID: profileID).history.entries, ["AUTH ••••••", "GET k"])
    }

    func testParseErrorSendsNothingAndClearEmptiesTheView() async {
        let keyspace = TransactionalKeyspace([:])
        let console = model(keyspace)
        _ = console.scrollView
        await console.submit("SET k \"unbalanced")
        XCTAssertTrue(keyspace.commands.isEmpty)
        XCTAssertEqual(console.buffer.lines.last, ConsoleLine("(error) Invalid argument(s): unbalanced quotes", kind: .error))

        console.clear()
        XCTAssertTrue(console.buffer.lines.isEmpty)
        XCTAssertEqual(console.textView?.string, "127.0.0.1:6379> ")
        await console.submit("clear")
        XCTAssertTrue(keyspace.commands.isEmpty)
    }

    func testHistoryNavigationAndReverseSearch() async {
        let console = model(TransactionalKeyspace(["a": "1"]))
        await console.submit("GET a")
        await console.submit("STRLEN a")
        XCTAssertEqual(console.historyPrevious(current: "TY"), "STRLEN a")
        XCTAssertEqual(console.historyPrevious(current: ""), "GET a")
        XCTAssertEqual(console.historyNext(), "STRLEN a")
        XCTAssertEqual(console.historyNext(), "TY")
        XCTAssertEqual(console.reverseSearch(), "STRLEN a")
        XCTAssertEqual(console.updateSearch("get"), "GET a")
        XCTAssertEqual(console.hint(for: "GET a", completion: ConsoleCompletion(), selected: 0), "  (reverse-i-search: 'get')")
        console.endSearch()
        XCTAssertNil(console.search)
    }
}

import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

private let writable = SafetyProfile(name: "local-dev", readOnly: false, server: "127.0.0.1:6379")

final class ConsoleSessionTests: XCTestCase {
    func testSelectIsConsoleScoped() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let console = ConsoleSession(service: service, profile: writable, database: 0)
        let prompt = await console.prompt
        XCTAssertEqual(prompt, "127.0.0.1:6379> ")

        let selected = await console.run(args("SELECT", "3"))
        XCTAssertEqual(selected, .printed([ConsoleLine("OK", kind: .output, reply: 1)]))
        let database = await console.database, moved = await console.prompt
        XCTAssertEqual(database, 3)
        XCTAssertEqual(moved, "127.0.0.1:6379[3]> ")

        // The console's next command runs on its own connection in db3; the browser's stays on db0.
        _ = await console.run(args("GET", "k"))
        _ = try await service.execute(.raw(args("GET", "k")), origin: .browser, context: DataContext(profile: writable, database: 0))
        XCTAssertEqual(server.opened.map(\.role), [.console(console.id), .browser(database: 0)])
        XCTAssertEqual(server.opened[0].transport.commands, [["SELECT", "3"], ["GET", "k"]])
        XCTAssertEqual(server.opened[1].transport.commands, [["GET", "k"]])
        XCTAssertEqual(server.opened[1].database, 0)
    }

    func testRefusalsPrintKeelErrorsAndSendNothing() async {
        let server = RecordingServer()
        let readOnly = SafetyProfile(name: "payments-prod", readOnly: true, server: "cache:6379")
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: readOnly, database: 0)
        let outcome = await console.run(args("SET", "k", "v"))
        XCTAssertEqual(outcome, .printed([ConsoleLine("(error) KEEL_READ_ONLY write commands are blocked on this connection", kind: .error, reply: 1)]))
        XCTAssertTrue(server.allCommands.isEmpty)
    }

    func testConfirmationRequiredBeforeFlushdb() async {
        let server = RecordingServer()
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: writable, database: 0)
        guard case .needsConfirmation(let request, _) = await console.run(args("FLUSHDB")) else { return XCTFail("FLUSHDB must ask first") }
        XCTAssertEqual(request.typedText, "db0")
        XCTAssertTrue(server.allCommands.isEmpty)
        let confirmed = await console.run(args("FLUSHDB"), confirmation: CommandConfirmation(scope: .command(args("FLUSHDB")), database: 0))
        XCTAssertEqual(confirmed, .printed([ConsoleLine("OK", kind: .output, reply: 2)]))
        XCTAssertEqual(server.allCommands, [["FLUSHDB"]])
    }
}

final class ConsoleHistoryTests: XCTestCase {
    func testDedupAndLimit() {
        var history = ConsoleHistory()
        history.add("GET a"); history.add("GET b"); history.add("GET a"); history.add("   ")
        // Running a line again moves it to the end; blank lines aren't kept.
        XCTAssertEqual(history.entries, ["GET b", "GET a"])
        for index in 0..<1_200 { history.add("SET k \(index)") }
        XCTAssertEqual(history.entries.count, ConsoleHistory.limit)
        XCTAssertEqual(history.entries.first, "SET k 200")
        XCTAssertEqual(history.entries.last, "SET k 1199")

        // ↑ walks back, ↓ returns to the line being typed.
        var small = ConsoleHistory()
        small.add("PING"); small.add("INFO")
        var cursor = ConsoleHistoryCursor()
        XCTAssertEqual(cursor.previous(in: small, current: "GE"), "INFO")
        XCTAssertEqual(cursor.previous(in: small, current: "ignored"), "PING")
        XCTAssertNil(cursor.previous(in: small, current: ""))
        XCTAssertEqual(cursor.next(in: small), "INFO")
        XCTAssertEqual(cursor.next(in: small), "GE")
        XCTAssertNil(cursor.next(in: small))
    }

    func testReverseSearch() {
        var history = ConsoleHistory()
        for line in ["HGET user:1 plan", "TTL user:1", "hget user:2 plan", "PING"] { history.add(line) }
        // Newest first, case-insensitive; asking again finds the next older match.
        let newest = history.search("hget")
        XCTAssertEqual(newest.map { history.entries[$0] }, "hget user:2 plan")
        let older = history.search("hget", before: newest)
        XCTAssertEqual(older.map { history.entries[$0] }, "HGET user:1 plan")
        XCTAssertNil(history.search("hget", before: older))
        XCTAssertNil(history.search("missing"))
        XCTAssertEqual(history.search(""), 3)
    }
}

final class ConsoleCompletionTests: XCTestCase {
    private let catalog = CommandCatalog.bundled

    func testCompletesCommandsAndSubcommands() {
        // AC2: HSC + Tab completes HSCAN and shows its syntax hint.
        let hsc = ConsoleCompleter.complete("HSC", catalog: catalog)
        XCTAssertEqual(hsc.candidates, ["HSCAN"])
        XCTAssertEqual(ConsoleCompleter.hint("HSC", completion: hsc, catalog: catalog), "AN key cursor [MATCH pattern] [COUNT count] [NOVALUES]")
        let completed = hsc.accept(0, in: "HSC")
        XCTAssertEqual(completed, "HSCAN")
        let after = ConsoleCompleter.complete(completed, catalog: catalog)
        XCTAssertFalse(after.showsList)
        XCTAssertEqual(ConsoleCompleter.hint(completed, completion: after, catalog: catalog), " key cursor [MATCH pattern] [COUNT count] [NOVALUES]")
        // Arguments already typed leave the hint.
        let typed = ConsoleCompleter.complete("hscan user:1 ", catalog: catalog)
        XCTAssertEqual(ConsoleCompleter.hint("hscan user:1 ", completion: typed, catalog: catalog), "cursor [MATCH pattern] [COUNT count] [NOVALUES]")

        // Lower case completes too, in catalog order.
        XCTAssertEqual(ConsoleCompleter.complete("hse", catalog: catalog).candidates, ["HSET", "HSETNX"])
        // Subcommands of a container.
        let client = ConsoleCompleter.complete("CLIENT LI", catalog: catalog)
        XCTAssertEqual(client.candidates, ["LIST"])
        XCTAssertEqual(client.accept(0, in: "CLIENT LI"), "CLIENT LIST")
        XCTAssertTrue(ConsoleCompleter.complete("XINFO ", catalog: catalog).candidates.contains("STREAM"))
        XCTAssertEqual(ConsoleCompleter.complete("XINFO ST", catalog: catalog).accept(0, in: "XINFO ST"), "XINFO STREAM")
        // Nothing past the names, and nothing for an unknown command.
        XCTAssertTrue(ConsoleCompleter.complete("GET k", catalog: catalog).candidates.isEmpty)
        XCTAssertTrue(ConsoleCompleter.complete("NOSUCH", catalog: catalog).candidates.isEmpty)
        XCTAssertEqual(ConsoleCompleter.hint("NOSUCH ", completion: ConsoleCompletion(), catalog: catalog), "")
    }
}

final class ConsoleMaskingTests: XCTestCase {
    private func display(_ line: String) throws -> String { ConsoleMasking.display(line, arguments: try ConsoleTokenizer.arguments(line)) }

    func testMasksCredentialArguments() throws {
        // AC4: the echo and history read `AUTH ••••••`.
        XCTAssertEqual(try display("AUTH secret"), "AUTH ••••••")
        XCTAssertEqual(try display("auth default \"s3 cret\""), "auth default ••••••")
        XCTAssertEqual(try display("HELLO 3 AUTH alice pw SETNAME keel"), "HELLO 3 AUTH alice •••••• SETNAME keel")
        XCTAssertEqual(try display("ACL SETUSER alice on >pw1 <old #abc ~* +@all"), "ACL SETUSER alice on >•••••• <•••••• #•••••• ~* +@all")
        XCTAssertEqual(try display("CONFIG SET requirepass hunter2 maxmemory 1gb masterauth x"), "CONFIG SET requirepass •••••• maxmemory 1gb masterauth ••••••")
        XCTAssertEqual(try display("MIGRATE 10.0.0.2 6379 \"\" 0 5000 COPY AUTH pw KEYS a auth"), "MIGRATE 10.0.0.2 6379 \"\" 0 5000 COPY AUTH •••••• KEYS a auth")
        XCTAssertEqual(try display("MIGRATE h 6379 k 0 5000 AUTH2 bob pw"), "MIGRATE h 6379 k 0 5000 AUTH2 bob ••••••")
        // Nothing else is touched, and the typed spelling stays.
        XCTAssertEqual(try display("SET  password  'hunter2'"), "SET  password  'hunter2'")
        XCTAssertEqual(try display("CONFIG GET requirepass"), "CONFIG GET requirepass")
        // A line that can't be split still hides what may be a secret.
        XCTAssertEqual(ConsoleMasking.displayUnparsed("AUTH \"secret"), "AUTH ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("GET \"k"), "GET \"k")
    }
}

final class ConsoleStreamingTests: XCTestCase {
    private func streamTransport(_ server: RecordingServer, _ console: ConsoleSession) -> RecordingTransport? {
        server.opened.first { $0.role == .stream(console.id) }?.transport
    }

    func testStopEndsMonitor() async throws {
        let server = RecordingServer()
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: writable, database: 0)
        guard case .streaming = await console.run(args("MONITOR")) else { return XCTFail("MONITOR streams") }
        let transport = try XCTUnwrap(streamTransport(server, console))
        transport.inject("+1700000000.000001 [0 127.0.0.1:50000] \"get\" \"k\"\r\n")
        var lines: [String] = []
        for _ in 0..<100 where lines.count < 2 {
            lines += await console.drainStream().lines.map(\.text)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(lines, ["OK", "1700000000.000001 [0 127.0.0.1:50000] \"get\" \"k\""])
        // Nothing but streaming runs meanwhile.
        let busy = await console.run(args("PING"))
        XCTAssertEqual(busy, .printed([]))

        // AC3: Stop ends MONITOR within 1 s and the console takes commands again.
        let clock = ContinuousClock(), start = clock.now
        await console.stopStream()
        XCTAssertLessThan(clock.now - start, .seconds(1))
        XCTAssertTrue(transport.isClosed)
        let drained = await console.drainStream(), streaming = await console.isStreaming
        XCTAssertTrue(drained.ended)
        XCTAssertFalse(streaming)
        let ping = await console.run(args("PING"))
        XCTAssertEqual(ping, .printed([ConsoleLine("OK", kind: .output, reply: 2)]))
    }

    func testOutputIsBounded() async throws {
        // The scrollback keeps the newest lines within its line and byte limits.
        var buffer = ConsoleBuffer()
        buffer.append(contentsOf: (0..<12_000).map { ConsoleLine("line \($0)", kind: .output) })
        XCTAssertEqual(buffer.lines.count, ConsoleBuffer.lineLimit)
        XCTAssertEqual(buffer.firstIndex, 2_000)
        XCTAssertEqual(buffer.lines.first?.text, "line 2000")
        XCTAssertEqual(buffer.endIndex, 12_000)
        var bytes = ConsoleBuffer(lineLimit: 100, byteLimit: 10)
        bytes.append(contentsOf: ["aaaa", "bbbb", "cccc"].map { ConsoleLine($0, kind: .output) })
        XCTAssertEqual(bytes.lines.map(\.text), ["bbbb", "cccc"])
        bytes.append(ConsoleLine(String(repeating: "x", count: 50), kind: .output))
        XCTAssertEqual(bytes.lines.map(\.text), [String(repeating: "x", count: 10)])
        bytes.clear()
        XCTAssertTrue(bytes.lines.isEmpty)
        XCTAssertEqual(bytes.firstIndex, bytes.endIndex)

        // A stream nobody drains keeps only its newest lines, and says how many it dropped.
        let server = RecordingServer()
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: writable, database: 0, streamLimit: 50)
        guard case .streaming = await console.run(args("SUBSCRIBE", "ch")) else { return XCTFail("SUBSCRIBE streams") }
        let transport = try XCTUnwrap(streamTransport(server, console))
        // One message of 200 lines, more than the 50 kept.
        transport.inject("*200\r\n" + (0..<200).map { "$\(String($0).count)\r\n\($0)\r\n" }.joined())
        var drained = ConsoleStreamDrain(lines: [], dropped: 0, ended: false)
        for _ in 0..<200 {
            drained = await console.drainStream()
            if drained.dropped > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(drained.lines.count, 50)
        XCTAssertEqual(drained.lines.last?.text, "200) \"199\"")
        XCTAssertGreaterThan(drained.dropped, 0)
        await console.stopStream()
    }
}

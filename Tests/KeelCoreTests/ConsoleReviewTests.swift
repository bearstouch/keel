import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review-driven console cases (KEEL-041): Stop during a size read sends nothing, a refused stream ends on its own,
/// TLS passphrases are masked.
final class ConsoleReviewTests: XCTestCase {
    private let writable = SafetyProfile(name: "local-dev", readOnly: false, server: "127.0.0.1:6379")

    func testStopDuringSizeReadSendsNothing() async throws {
        // HLEN never answers, so HGETALL waits on its size read until Stop.
        let server = RecordingServer { $0.first?.uppercased() == "HLEN" ? "" : "+OK\r\n" }
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: writable, database: 0)
        let running = Task { await console.run(args("HGETALL", "h")) }
        for _ in 0..<200 where !server.allCommands.contains(["HLEN", "h"]) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(server.allCommands, [["HLEN", "h"]])
        await console.cancel()
        let outcome = await running.value
        XCTAssertEqual(outcome, .printed([ConsoleLine("Not sent.", kind: .notice, reply: 1)]))
        XCTAssertFalse(server.allCommands.contains(["HGETALL", "h"]))
        // The next command reconnects and runs.
        let ping = await console.run(args("PING"))
        XCTAssertEqual(ping, .printed([ConsoleLine("OK", kind: .output, reply: 2)]))
    }

    func testRefusedStreamEndsWithoutStop() async throws {
        let server = RecordingServer { $0.first?.uppercased() == "MONITOR" ? "-NOPERM this user has no permissions to run the 'monitor' command\r\n" : "+OK\r\n" }
        let console = ConsoleSession(service: DataCommandService(session: server.session()), profile: writable, database: 0)
        guard case .streaming = await console.run(args("MONITOR")) else { return XCTFail("MONITOR streams") }
        var lines: [String] = [], ended = false
        for _ in 0..<200 where !ended {
            let drained = await console.drainStream()
            lines += drained.lines.map(\.text); ended = drained.ended
            if !ended { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(lines, ["(error) NOPERM this user has no permissions to run the 'monitor' command"])
        let streaming = await console.isStreaming
        XCTAssertFalse(streaming)
    }

    func testMasksTLSPassphrases() throws {
        let line = "CONFIG SET tls-key-file-pass k1 tls-client-key-file-pass k2"
        XCTAssertEqual(ConsoleMasking.display(line, arguments: try ConsoleTokenizer.arguments(line)), "CONFIG SET tls-key-file-pass •••••• tls-client-key-file-pass ••••••")
    }

    func testUnparsedLineWithQuotedCredentialNameHidesTheRest() {
        // FR-CO10: the name is read like the tokenizer reads it, so quoting it doesn't leak the secret.
        XCTAssertEqual(ConsoleMasking.displayUnparsed("\"AUTH\" \"s3cret"), "AUTH ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("  'auth' default 's3cret"), "auth ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("\"AUTH s3cret"), "AUTH ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("A\"UTH\" s3cret \""), "AUTH ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("\"\\x41UTH\" s3cret \""), "AUTH ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("'Config' SET requirepass 'pw"), "Config ••••••")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("\"hello\" 3 AUTH u \"pw"), "hello ••••••")
        // Other unparseable lines still echo as typed.
        XCTAssertEqual(ConsoleMasking.displayUnparsed("\"GET\" \"k"), "\"GET\" \"k")
        XCTAssertEqual(ConsoleMasking.displayUnparsed("AUTH \"secret"), "AUTH ••••••")
    }

    func testHelloMasksThePasswordOfTheAuthOption() throws {
        func display(_ line: String) throws -> String { ConsoleMasking.display(line, arguments: try ConsoleTokenizer.arguments(line)) }
        // A SETNAME value spelled `auth` isn't the AUTH option.
        XCTAssertEqual(try display("HELLO 3 SETNAME auth AUTH user secret"), "HELLO 3 SETNAME auth AUTH user ••••••")
        XCTAssertEqual(try display("HELLO 3 SETNAME auth"), "HELLO 3 SETNAME auth")
        XCTAssertEqual(try display("hello 3 auth alice pw setname keel"), "hello 3 auth alice •••••• setname keel")
        XCTAssertEqual(try display("HELLO 3"), "HELLO 3")
        // Unsure: a short AUTH, a missing protover or an unknown option hides everything from there on.
        XCTAssertEqual(try display("HELLO 3 AUTH secret"), "HELLO 3 AUTH ••••••")
        XCTAssertEqual(try display("HELLO AUTH alice pw"), "HELLO AUTH alice ••••••")
        XCTAssertEqual(try display("HELLO 3 SETNAMEX auth alice pw"), "HELLO 3 •••••• •••••• •••••• ••••••")
    }
}

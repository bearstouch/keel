import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class ConsoleTokenizerTests: XCTestCase {
    private func split(_ line: String) throws -> [Data] { try ConsoleTokenizer.arguments(line) }
    private func bytes(_ values: [UInt8]...) -> [Data] { values.map { Data($0) } }

    // MARK: - Story tests

    /// FR-CO02: the escape table inside double quotes, as redis-cli's `sdssplitargs` reads it.
    func testEscapes() throws {
        let table: [(String, [UInt8])] = [
            (#""\n""#, [0x0A]), (#""\r""#, [0x0D]), (#""\t""#, [0x09]), (#""\b""#, [0x08]), (#""\a""#, [0x07]),
            (#""\\""#, [0x5C]), (#""\"""#, [0x22]), (#""\x00""#, [0x00]), (#""\xff""#, [0xFF]), (#""\xAb""#, [0xAB]),
            // Any other escaped character stands for itself; `\x` without two hex digits is a plain `x`.
            (#""\q""#, [0x71]), (#""\'""#, [0x27]), (#""\x4""#, [0x78, 0x34]), (#""\xzz""#, [0x78, 0x7A, 0x7A]),
            (#""""#, []), (#""é""#, [0xC3, 0xA9])
        ]
        for (line, expected) in table { XCTAssertEqual(try split(line), [Data(expected)], line) }

        // AC1: `SET k "a\x00b"` carries a 3-byte value.
        let set = try split(#"SET k "a\x00b""#)
        XCTAssertEqual(set, [Data("SET".utf8), Data("k".utf8), Data([0x61, 0x00, 0x62])])
        XCTAssertEqual(set[2].count, 3)
    }

    /// AC1 on the wire: the tokenized line reaches the server as a 3-byte bulk string through the data path.
    func testNulEscapeIsSentAsThreeBytes() async throws {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false), consoleID: UUID())
        _ = try await service.execute(.raw(try split(#"SET k "a\x00b""#)), origin: .console, context: context)
        let frames = server.opened.flatMap { $0.transport.sent }
        XCTAssertEqual(frames.last, Data("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\na\u{0}b\r\n".utf8))
    }

    func testSingleQuotesAreLiteral() throws {
        XCTAssertEqual(try split(#"SET k 'a\nb\x00 "c"'"#), [Data("SET".utf8), Data("k".utf8), Data(#"a\nb\x00 "c""#.utf8)])
        // `\'` is redis-cli's one escape inside single quotes; `\\` stays two backslashes.
        XCTAssertEqual(try split(#"'it\'s' 'a\\b'"#), [Data("it's".utf8), Data(#"a\\b"#.utf8)])
        XCTAssertEqual(try split("''"), [Data()])
    }

    /// AC3: an unbalanced quote is an error (nothing to send), as is text glued to a closing quote.
    func testUnbalancedQuotes() throws {
        for line in [#"SET k "abc"#, "SET k 'abc", #"GET "a\"#, #"SET k "a\""#, "'", "\""] {
            XCTAssertThrowsError(try split(line), line) { XCTAssertEqual($0 as? ConsoleParseError, .unbalancedQuotes, line) }
        }
        for line in [#"GET "a"b"#, "GET 'a'b", #"GET "a""b""#] {
            XCTAssertThrowsError(try split(line), line) { XCTAssertEqual($0 as? ConsoleParseError, .textAfterClosingQuote, line) }
        }
        XCTAssertEqual(ConsoleParseError.unbalancedQuotes.code, "INVALID_PARAMS")
        XCTAssertEqual(ConsoleParseError.unbalancedQuotes.message, "Invalid argument(s): unbalanced quotes")
    }

    // MARK: - Splitting rules

    func testWhitespaceSplitting() throws {
        XCTAssertEqual(try split("  GET   key  "), [Data("GET".utf8), Data("key".utf8)])
        XCTAssertEqual(try split("a\tb\nc\rd"), ["a", "b", "c", "d"].map { Data($0.utf8) })
        XCTAssertEqual(try split(""), [])
        XCTAssertEqual(try split(" \t "), [])
        // A quote can start mid-argument and a closing quote may end the line or meet any whitespace.
        XCTAssertEqual(try split(#"a"b c" d"#), [Data("ab c".utf8), Data("d".utf8)])
        XCTAssertEqual(try split("\"a\"\t'b'"), [Data("a".utf8), Data("b".utf8)])
        // Backslashes outside quotes are literal.
        XCTAssertEqual(try split(#"a\nb"#), [Data(#"a\nb"#.utf8)])
    }

    /// redis-cli reads a C string: a NUL ends the line, so nothing after it becomes an argument.
    func testNulEndsLine() throws {
        XCTAssertEqual(try split("GET a\u{0}b c"), [Data("GET".utf8), Data("a".utf8)])
        XCTAssertThrowsError(try split("GET \"a\u{0}b\""))
    }
}

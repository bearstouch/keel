import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Golden outputs in `Tests/Fixtures/Console` (captured by `scripts/capture-console-goldens.py`): each case's raw reply
/// (`.resp`) and what redis-cli printed for it (`.txt`), per protocol. Cases redis-cli can't print have no `.txt`.
final class RedisCliFormatterTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Console")

    private func cases() throws -> [String] {
        try String(contentsOf: Self.fixtures.appendingPathComponent("cases.txt"), encoding: .utf8).split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
    }

    /// Formats every captured reply and compares it byte for byte with redis-cli; returns how many cases were compared.
    @discardableResult
    private func assertGoldens(_ protocolFolder: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        var compared = 0
        for name in try cases() {
            let folder = Self.fixtures.appendingPathComponent(protocolFolder)
            let expectedURL = folder.appendingPathComponent(name + ".txt")
            guard FileManager.default.fileExists(atPath: expectedURL.path) else { continue }
            var parser = RESPParser()
            parser.append(try Data(contentsOf: folder.appendingPathComponent(name + ".resp")))
            let reply = try XCTUnwrap(try parser.next(), "\(protocolFolder)/\(name)", file: file, line: line)
            XCTAssertNil(try parser.next(), "\(protocolFolder)/\(name): one reply per fixture", file: file, line: line)
            XCTAssertEqual(Data(RedisCliFormatter.format(reply).utf8), try Data(contentsOf: expectedURL), "\(protocolFolder)/\(name)", file: file, line: line)
            compared += 1
        }
        return compared
    }

    // MARK: - Story tests

    func testGoldenRESP2Outputs() throws {
        // Every RESP2 case has a golden: redis-cli prints all of them.
        XCTAssertEqual(try assertGoldens("resp2"), try cases().count)
    }

    func testGoldenRESP3Outputs() throws {
        // Big numbers and attributes make redis-cli 7.2 exit, so those two have no golden (see the next tests).
        XCTAssertEqual(try assertGoldens("resp3"), try cases().count - 2)
    }

    func testNestedArrayIndentation() {
        let s = { (text: String) in RESPValue.bulkString(Data(text.utf8)) }
        // Index width follows the widest index; nested lines indent past it.
        let wide = RESPValue.array((1...10).map { .array([s("id-\($0)"), .array([s("f"), s("v")])]) })
        let lines = RedisCliFormatter.format(wide).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], #" 1) 1) "id-1""#)
        XCTAssertEqual(lines[1], #"    2) 1) "f""#)
        XCTAssertEqual(lines[2], #"       2) "v""#)
        XCTAssertEqual(lines[27], #"10) 1) "id-10""#)
        XCTAssertEqual(lines[28], #"    2) 1) "f""#)
        // Empty aggregates nest inline; a map value spanning lines starts on its own line with its first index indented.
        let map = RESPValue.map([RESPPair(s("a"), .array([])), RESPPair(s("b"), .map([RESPPair(s("c"), .set([s("x"), s("y")]))]))])
        XCTAssertEqual(RedisCliFormatter.format(map), "1# \"a\" => (empty array)\n2# \"b\" => \n   1# \"c\" => \n      1~ \"x\"\n      2~ \"y\"\n")
        XCTAssertEqual(RedisCliFormatter.format(.array([.array([.array([])])])), "1) 1) (empty array)\n")
    }

    // MARK: - Types without a redis-cli golden

    func testScalarsAndEmptyAggregates() {
        XCTAssertEqual(RedisCliFormatter.format(.bigNumber("-1234567999999999999999999")), "(big number) -1234567999999999999999999\n")
        XCTAssertEqual(RedisCliFormatter.format(.blobError(Data("SYNTAX bad".utf8))), "(error) SYNTAX bad\n")
        XCTAssertEqual(RedisCliFormatter.format(.nullArray), "(nil)\n")
        XCTAssertEqual(RedisCliFormatter.format(.push([])), "(empty push)\n")
        XCTAssertEqual(RedisCliFormatter.format(.push([.bulkString(Data("message".utf8)), .integer(1)])), "1) \"message\"\n2) (integer) 1\n")
        // An attribute is shown as the reply it annotates.
        let attributed = RESPValue.attribute([RESPPair(.simpleString(Data("ttl".utf8)), .integer(3))], .bulkString(Data("v".utf8)))
        XCTAssertEqual(RedisCliFormatter.format(attributed), "\"v\"\n")
        // A map key ending in "\r" still loses only its own newline before ` => `.
        XCTAssertEqual(RedisCliFormatter.format(.map([RESPPair(.simpleString(Data("k\r".utf8)), .integer(1))])), "1# k\r => (integer) 1\n")
    }

    /// Doubles print as Redis 7 sends them (probed against redis-server 7.2), since redis-cli echoes the server text.
    func testDoubleText() {
        let table: [(Double, String)] = [
            (1, "1"), (1.5, "1.5"), (-2.25, "-2.25"), (0.1 + 0.2, "0.30000000000000004"), (1e-6, "0.000001"), (1e-5, "0.00001"),
            (1e-7, "1e-7"), (1.5e-6, "1.5e-6"), (0.00012345, "1.2345e-4"), (1e18, "1000000000000000000"), (1e19, "1e+19"),
            (1.5e19, "1.5e+19"), (1.5e17, "150000000000000000"), (123_456_789_012_345_678, "123456789012345680"), (1e21, "1e+21"),
            (12345678.9, "12345678.9"), (33.333333333333336, "33.333333333333336"), (1.7976931348623157e308, "1.7976931348623157e+308"),
            (5e-324, "5e-324"), (-1e21, "-1e+21"), (.infinity, "inf"), (-.infinity, "-inf"), (.nan, "nan"), (0, "0"), (-0.0, "-0")
        ]
        for (value, text) in table { XCTAssertEqual(RedisCliFormatter.serverText(value), text, "\(value)") }
    }
}

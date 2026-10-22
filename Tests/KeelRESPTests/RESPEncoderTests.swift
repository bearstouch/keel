import Foundation
import XCTest
@testable import KeelRESP

final class RESPEncoderTests: XCTestCase {
    private typealias F = RESPFixtures

    func testEncodesArgumentsAsBulkArray() {
        XCTAssertEqual(RESPEncoder.command([F.data("SET"), F.data("k"), F.data("v")]), F.data("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n"))
        XCTAssertEqual(RESPEncoder.command([F.data("GET"), Data()]), F.data("*2\r\n$3\r\nGET\r\n$0\r\n\r\n"))
        // Bytes are length-prefixed, never escaped or re-encoded.
        let key = Data([0x6B, 0x0D, 0x0A, 0x00, 0xFF])
        XCTAssertEqual(RESPEncoder.command([F.data("DEL"), key]), F.data("*2\r\n$3\r\nDEL\r\n$5\r\n") + key + F.data("\r\n"))
    }

    func testRejectsUnframeableValues() {
        let cases: [(RESPValue, RESPError)] = [
            (.simpleString(F.data("a\r\nb")), .protocolError(.unframeable)), (.error(F.data("a\nb")), .protocolError(.unframeable)),
            (.bigNumber("12a"), .protocolError(.invalidBigNumber)), (.bigNumber(""), .protocolError(.invalidBigNumber)),
            (.verbatim(format: "text", Data()), .protocolError(.invalidVerbatim)), (.verbatim(format: "t t", Data()), .protocolError(.invalidVerbatim))
        ]
        for (value, error) in cases { XCTAssertThrowsError(try RESPEncoder.encode(value)) { XCTAssertEqual($0 as? RESPError, error, "\(value)") } }
        let deep = (0..<129).reduce(RESPValue.integer(1)) { value, _ in .array([value]) }
        XCTAssertThrowsError(try RESPEncoder.encode(deep)) { XCTAssertEqual($0 as? RESPError, .protocolError(.nestingTooDeep)) }
    }

    func testEncodesDoublesInParserGrammar() throws {
        for number in [0, -0.0, 1, 0.1, 1e16, 5e-324, .greatestFiniteMagnitude, -.infinity, .nan] {
            XCTAssertEqual(try F.parse(Array(try RESPEncoder.encode(.double(number)))), [.double(number)], "\(number)")
        }
    }
}

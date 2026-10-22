import Foundation
import XCTest
@testable import KeelRESP

final class RESPReviewTests: XCTestCase {
    private typealias F = RESPFixtures

    /// Attribute wrappers nest the value they annotate, so a run of empty attributes must count toward the depth
    /// limit; unbounded, a few megabytes of `|0` built a value whose recursive deinit overflowed the stack.
    func testAttributeChainsCountTowardNesting() throws {
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "|0\r\n", count: 1_000_000) + ":1\r\n")), .protocolError(.nestingTooDeep))
        XCTAssertEqual(F.failure(F.bytes("*1\r\n" + String(repeating: "|0\r\n", count: 1_000_000) + ":1\r\n")), .protocolError(.nestingTooDeep))
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "|1\r\n:1\r\n:2\r\n*1\r\n", count: 70) + ":1\r\n")), .protocolError(.nestingTooDeep))
        // 127 wrappers plus one aggregate is the deepest accepted value.
        XCTAssertEqual(try F.parse(F.bytes(String(repeating: "|0\r\n", count: 127) + "*0\r\n")).count, 1)
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "|0\r\n", count: 128) + "*0\r\n")), .protocolError(.nestingTooDeep))
        // Wrappers consumed by a finished value free their depth for the next sibling.
        let sibling = "|0\r\n:1\r\n"
        XCTAssertEqual(try F.parse(F.bytes("*200\r\n" + String(repeating: sibling, count: 200))).count, 1)
        XCTAssertEqual(try F.parse(F.bytes(String(repeating: sibling, count: 300))).count, 300)
    }

    func testEncoderBoundsAttributeChains() throws {
        let chain = (0..<200).reduce(RESPValue.integer(1)) { value, _ in .attribute([], value) }
        XCTAssertThrowsError(try RESPEncoder.encode(chain)) { XCTAssertEqual($0 as? RESPError, .protocolError(.nestingTooDeep)) }
        // The deepest reply the parser accepts (127 wrappers around an aggregate) still encodes.
        let deepest = (0..<127).reduce(RESPValue.array([.integer(1)])) { value, _ in .attribute([], value) }
        XCTAssertEqual(try RESPFixtures.parse(Array(try RESPEncoder.encode(deepest))), [deepest])
    }
}

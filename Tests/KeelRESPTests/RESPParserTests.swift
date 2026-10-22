import Foundation
import XCTest
@testable import KeelRESP

final class RESPParserTests: XCTestCase {
    private typealias F = RESPFixtures

    func testParsesEveryRESP2Type() throws {
        for (frame, value) in F.resp2 { XCTAssertEqual(try F.parse(frame), [value], String(decoding: frame, as: UTF8.self)) }
    }

    func testParsesEveryRESP3Type() throws {
        for (frame, value) in F.resp3 { XCTAssertEqual(try F.parse(frame), [value], String(decoding: frame, as: UTF8.self)) }
        // NaN is decoded as NaN, not merely "equal under RESPValue's rule".
        guard case .double(let nan) = try F.parse(F.bytes(",nan\r\n"))[0] else { return XCTFail("not a double") }
        XCTAssertTrue(nan.isNaN)
        // Accepted spellings that re-encode canonically.
        XCTAssertEqual(try F.parse(F.bytes(",3\r\n:+7\r\n,1.5E-3\r\n")), [.double(3), .integer(7), .double(0.0015)])
    }

    func testRoundTripsEveryTypeByteExactly() throws {
        for (frame, value) in F.all {
            XCTAssertEqual(Array(try RESPEncoder.encode(value)), frame, String(decoding: frame, as: UTF8.self))
            XCTAssertEqual(try F.parse(Array(try RESPEncoder.encode(value))), [value])
        }
    }

    func testChunkBoundariesProduceSameValue() throws {
        for (frame, value) in F.all {
            for cut in 0...frame.count {
                XCTAssertEqual(try F.parse([frame[..<cut], frame[cut...]]), [value], "cut at \(cut) of \(String(decoding: frame, as: UTF8.self))")
            }
            XCTAssertEqual(try F.parse(frame.map { [$0][...] }), [value], "byte at a time")
        }
        // Every fixture pipelined back to back, split at every offset, still yields each reply in order.
        let stream = F.all.flatMap(\.frame)
        for cut in stride(from: 0, through: stream.count, by: 7) {
            XCTAssertEqual(try F.parse([stream[..<cut], stream[cut...]]), F.all.map(\.value))
        }
    }

    func testIncompleteReplyWaitsForMoreBytes() throws {
        var parser = RESPParser()
        parser.append(F.bytes("*2\r\n$5\r\nhel"))
        XCTAssertNil(try parser.next())
        parser.append(F.bytes("lo\r\n:7\r\n+O"))
        XCTAssertEqual(try parser.next(), .array([.bulkString(F.data("hello")), .integer(7)]))
        XCTAssertNil(try parser.next())
        parser.append(F.bytes("K\r\n"))
        XCTAssertEqual(try parser.next(), .simpleString(F.data("OK")))
    }

    func testBinarySafeBulkStrings() throws {
        for (frame, value) in F.binary { XCTAssertEqual(try F.parse(frame), [value]) }
        // Every byte value, including CR, LF and NUL, survives in order.
        let all = Data((0...255).map(UInt8.init))
        let frame = Array(RESPEncoder.command([all, all]))
        XCTAssertEqual(try F.parse(frame), [.array([.bulkString(all), .bulkString(all)])])
    }

    func testRejectsNegativeAndHugeLengths() throws {
        let invalid = ["$-2\r\n", "*-5\r\n", "%-1\r\n", "~-1\r\n", "!-1\r\n", "=-1\r\n", "$+5\r\n", "$-0\r\n", "$\r\n", "$1x\r\n", "$99999999999999999999\r\n"]
        for frame in invalid { XCTAssertEqual(F.failure(F.bytes(frame)), .protocolError(.invalidLength), frame) }
        for frame in [":\r\n", ":12a\r\n", ":9223372036854775808\r\n", ":-\r\n", ": 1\r\n"] { XCTAssertEqual(F.failure(F.bytes(frame)), .protocolError(.invalidInteger), frame) }
        XCTAssertEqual(F.failure(F.bytes("$?\r\n;4\r\nHell\r\n;0\r\n")), .protocolError(.streamedType))

        // A declared size over 64 MiB fails on the header, before any payload arrives.
        var parser = RESPParser()
        parser.append(F.bytes("$67108863\r\n"))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? RESPError, .limitExceeded(.replyBytes)) }
        XCTAssertEqual(F.failure(F.bytes("*\(RESPLimits.standard.maxElements + 1)\r\n")), .limitExceeded(.elements))
        XCTAssertEqual(F.failure(F.bytes("%\(RESPLimits.standard.maxElements / 2 + 1)\r\n")), .limitExceeded(.elements))

        // Declared sizes within the limits wait for data without reserving it.
        for header in ["$60000000\r\n", "*4000000\r\n", "%2000000\r\n"] {
            var parser = RESPParser()
            parser.append(F.bytes(header + "$1\r\na\r\n"))
            XCTAssertNil(try parser.next())
            XCTAssertLessThan(parser.reservedCapacity, 1_048_576, header)
        }
    }

    func testRejectsExcessiveNesting() throws {
        let deepest = String(repeating: "*1\r\n", count: 127) + "*0\r\n"
        XCTAssertEqual(try F.parse(F.bytes(deepest)).count, 1, "128 levels are allowed")
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "*1\r\n", count: 128) + "*0\r\n")), .protocolError(.nestingTooDeep))
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "%1\r\n:1\r\n", count: 129))), .protocolError(.nestingTooDeep))
        XCTAssertEqual(F.failure(F.bytes(String(repeating: "*1\r\n", count: 1_000_000))), .protocolError(.nestingTooDeep))
    }

    func testRejectsMalformedFrames() {
        let cases: [(String, RESPViolation)] = [
            ("HTTP/1.1 400 Bad Request\r\n", .unknownType), ("\r\n", .unknownType), ("SSH-2.0-OpenSSH\r\n", .unknownType),
            ("+OK\rX", .invalidLineEnding), ("+OK\n", .invalidLineEnding), ("$3\r\nabcd\r\n", .invalidLineEnding), ("$3\r\nab\r\n\r\n", .invalidLineEnding),
            (",1.\r\n", .invalidDouble), (",.5\r\n", .invalidDouble), (",0x1p3\r\n", .invalidDouble), (",infinity\r\n", .invalidDouble), (",1e\r\n", .invalidDouble), (",\r\n", .invalidDouble),
            ("#x\r\n", .invalidBoolean), ("#tt\r\n", .invalidBoolean), ("_x\r\n", .invalidNull), ("(12a\r\n", .invalidBigNumber), ("(\r\n", .invalidBigNumber),
            ("=3\r\ntxt\r\n", .invalidVerbatim), ("=5\r\ntxtx1\r\n", .invalidVerbatim), ("=5\r\nt t:1\r\n", .invalidVerbatim),
            (":" + String(repeating: "1", count: 40), .invalidInteger), ("*" + String(repeating: "1", count: 40), .invalidLength)
        ]
        for (frame, violation) in cases { XCTAssertEqual(F.failure(F.bytes(frame)), .protocolError(violation), frame.debugDescription) }
    }

    func testReplyByteLimitCountsWholeReply() throws {
        let small = RESPLimits(maxReplyBytes: 32, maxDepth: 8, maxElements: 64)
        XCTAssertEqual(try F.parse(F.bytes("*2\r\n$5\r\nhello\r\n$3\r\nabc\r\n"), limits: small).count, 1)
        // Many small elements exceed the byte cap even though none is large.
        XCTAssertEqual(F.failure(F.bytes("*20\r\n" + String(repeating: ":1\r\n", count: 20)), limits: small), .limitExceeded(.replyBytes))
        // An unterminated line can't grow past the cap.
        XCTAssertEqual(F.failure(F.bytes("+" + String(repeating: "a", count: 40)), limits: small), .limitExceeded(.replyBytes))
        // The cap applies per reply: pipelined replies each start from zero.
        XCTAssertEqual(try F.parse(F.bytes(String(repeating: "$20\r\naaaaaaaaaaaaaaaaaaaa\r\n", count: 10)), limits: small).count, 10)
        XCTAssertEqual(F.failure(F.bytes("*65\r\n"), limits: small), .limitExceeded(.elements))
    }

    func testFailureIsStickyAndIgnoresLaterBytes() {
        var parser = RESPParser()
        parser.append(F.bytes("+OK\r\n:x\r\n+OK\r\n"))
        XCTAssertEqual(try parser.next(), .simpleString(F.data("OK")))
        for _ in 0..<2 { XCTAssertThrowsError(try parser.next()) { XCTAssertEqual($0 as? RESPError, .protocolError(.invalidInteger)) } }
        parser.append(F.bytes("+OK\r\n"))
        XCTAssertThrowsError(try parser.next()) { XCTAssertEqual(($0 as? RESPError)?.code, "PROTOCOL_ERROR") }
        XCTAssertEqual(RESPError.limitExceeded(.elements).code, "LIMIT_EXCEEDED")
    }

    func testLargeReplyArrivingInSmallChunks() throws {
        // 300k elements in 1 KiB chunks: resumable parsing keeps this linear, and the buffer is compacted.
        let items = (0..<300_000).map { RESPValue.integer(Int64($0)) }
        let frame = Array(try RESPEncoder.encode(.array(items)))
        let chunks = stride(from: 0, to: frame.count, by: 1_024).map { frame[$0..<min($0 + 1_024, frame.count)] }
        XCTAssertEqual(try F.parse(chunks), [.array(items)])
    }
}

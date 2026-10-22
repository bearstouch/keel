import Foundation
@testable import KeelRESP

/// Canonical frames and the values they decode to. Every frame re-encodes to exactly these bytes.
enum RESPFixtures {
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static let resp2: [(frame: [UInt8], value: RESPValue)] = [
        (bytes("+OK\r\n"), .simpleString(data("OK"))),
        (bytes("+\r\n"), .simpleString(Data())),
        (bytes("-ERR unknown command 'FOO'\r\n"), .error(data("ERR unknown command 'FOO'"))),
        (bytes(":0\r\n"), .integer(0)),
        (bytes(":-42\r\n"), .integer(-42)),
        (bytes(":9223372036854775807\r\n"), .integer(.max)),
        (bytes(":-9223372036854775808\r\n"), .integer(.min)),
        (bytes("$5\r\nhello\r\n"), .bulkString(data("hello"))),
        (bytes("$0\r\n\r\n"), .bulkString(Data())),
        (bytes("$-1\r\n"), .nullBulkString),
        (bytes("*-1\r\n"), .nullArray),
        (bytes("*0\r\n"), .array([])),
        (bytes("*3\r\n:1\r\n$3\r\nfoo\r\n+bar\r\n"), .array([.integer(1), .bulkString(data("foo")), .simpleString(data("bar"))])),
        (bytes("*2\r\n*1\r\n:1\r\n*2\r\n$-1\r\n-ERR x\r\n"), .array([.array([.integer(1)]), .array([.nullBulkString, .error(data("ERR x"))])]))
    ]

    static let resp3: [(frame: [UInt8], value: RESPValue)] = [
        (bytes("_\r\n"), .null),
        (bytes(",1.5\r\n"), .double(1.5)),
        (bytes(",-0.25\r\n"), .double(-0.25)),
        (bytes(",1e+100\r\n"), .double(1e100)),
        (bytes(",inf\r\n"), .double(.infinity)),
        (bytes(",-inf\r\n"), .double(-.infinity)),
        (bytes(",nan\r\n"), .double(.nan)),
        (bytes("#t\r\n"), .boolean(true)),
        (bytes("#f\r\n"), .boolean(false)),
        (bytes("(3492890328409238509324850943850943825024385\r\n"), .bigNumber("3492890328409238509324850943850943825024385")),
        (bytes("(-1\r\n"), .bigNumber("-1")),
        (bytes("!21\r\nSYNTAX invalid syntax\r\n"), .blobError(data("SYNTAX invalid syntax"))),
        (bytes("=15\r\ntxt:Some string\r\n"), .verbatim(format: "txt", data("Some string"))),
        (bytes("=4\r\nmkd:\r\n"), .verbatim(format: "mkd", Data())),
        (bytes("%2\r\n+first\r\n:1\r\n+second\r\n:2\r\n"), .map([RESPPair(.simpleString(data("first")), .integer(1)), RESPPair(.simpleString(data("second")), .integer(2))])),
        (bytes("%0\r\n"), .map([])),
        (bytes("~3\r\n:1\r\n#t\r\n_\r\n"), .set([.integer(1), .boolean(true), .null])),
        (bytes(">3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$2\r\nhi\r\n"), .push([.bulkString(data("message")), .bulkString(data("ch")), .bulkString(data("hi"))])),
        (
            bytes("|1\r\n+key-popularity\r\n%1\r\n$1\r\na\r\n,0.1923\r\n*2\r\n:2039123\r\n:9543892\r\n"),
            .attribute([RESPPair(.simpleString(data("key-popularity")), .map([RESPPair(.bulkString(data("a")), .double(0.1923))]))], .array([.integer(2_039_123), .integer(9_543_892)]))
        ),
        (bytes("*2\r\n|1\r\n+ttl\r\n:3600\r\n:1\r\n:2\r\n"), .array([.attribute([RESPPair(.simpleString(data("ttl")), .integer(3600))], .integer(1)), .integer(2)])),
        (bytes("|0\r\n|1\r\n:1\r\n:2\r\n#t\r\n"), .attribute([], .attribute([RESPPair(.integer(1), .integer(2))], .boolean(true))))
    ]

    /// Bulk payloads with every byte that could confuse framing.
    static let binary: [(frame: [UInt8], value: RESPValue)] = [
        (bytes("$4\r\n\r\n\r\n\r\n"), .bulkString(data("\r\n\r\n"))),
        (bytes("$5\r\n") + [0, 0x0D, 0x00, 0x0A, 0xFF] + bytes("\r\n"), .bulkString(Data([0, 0x0D, 0x00, 0x0A, 0xFF]))),
        (bytes("!3\r\n") + [0x0D, 0, 0x0A] + bytes("\r\n"), .blobError(Data([0x0D, 0, 0x0A]))),
        (bytes("=7\r\ntxt:") + [0x0D, 0x0A, 0] + bytes("\r\n"), .verbatim(format: "txt", Data([0x0D, 0x0A, 0]))),
        (bytes("%1\r\n$2\r\n") + [0x0D, 0x0A] + bytes("\r\n$1\r\n") + [0] + bytes("\r\n"), .map([RESPPair(.bulkString(Data([0x0D, 0x0A])), .bulkString(Data([0])))])),
        (bytes("+caf\u{e9}\r\n"), .simpleString(data("caf\u{e9}")))
    ]

    static var all: [(frame: [UInt8], value: RESPValue)] { resp2 + resp3 + binary }

    /// Feeds `chunks` in order and drains every reply.
    static func parse(_ chunks: [ArraySlice<UInt8>], limits: RESPLimits = .standard) throws(RESPError) -> [RESPValue] {
        var parser = RESPParser(limits: limits)
        var values: [RESPValue] = []
        for chunk in chunks {
            parser.append(chunk)
            while let value = try parser.next() { values.append(value) }
        }
        return values
    }

    static func parse(_ frame: [UInt8], limits: RESPLimits = .standard) throws(RESPError) -> [RESPValue] { try parse([frame[...]], limits: limits) }

    /// The error a frame fails with, or nil when it parses (complete or not).
    static func failure(_ frame: [UInt8], limits: RESPLimits = .standard) -> RESPError? {
        do { _ = try parse(frame, limits: limits); return nil } catch { return error }
    }
}

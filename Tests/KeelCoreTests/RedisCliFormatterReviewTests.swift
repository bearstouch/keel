import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review cases: map value layouts printed by redis-cli 7.2.1 (`-3 --no-raw`) for hand-built RESP3 replies.
final class RedisCliFormatterReviewTests: XCTestCase {
    private func format(_ resp: String) throws -> String {
        var parser = RESPParser()
        parser.append(Data(resp.utf8))
        return RedisCliFormatter.format(try XCTUnwrap(try parser.next()))
    }

    /// Only a map value that spans lines starts on its own line; a one-element aggregate of a scalar stays inline.
    func testMapValueStartsOwnLineOnlyWhenMultiLine() throws {
        let cases: [(String, String)] = [
            ("%1\r\n+a\r\n*1\r\n:1\r\n", "1# a => 1) (integer) 1\n"),
            ("%1\r\n+a\r\n*1\r\n*1\r\n:1\r\n", "1# a => 1) 1) (integer) 1\n"),
            ("%1\r\n+a\r\n*1\r\n*0\r\n", "1# a => 1) (empty array)\n"),
            ("%1\r\n+a\r\n*1\r\n%1\r\n+b\r\n:1\r\n", "1# a => 1) 1# b => (integer) 1\n"),
            ("~2\r\n~1\r\n:1\r\n%1\r\n+a\r\n%1\r\n+b\r\n:1\r\n", "1~ 1~ (integer) 1\n2~ 1# a => 1# b => (integer) 1\n"),
            // A multi-line key doesn't count.
            ("%1\r\n+a\r\n%1\r\n*2\r\n:1\r\n:2\r\n:3\r\n", "1# a => 1# 1) (integer) 1\n      2) (integer) 2 => (integer) 3\n"),
            ("%1\r\n+a\r\n*1\r\n=7\r\ntxt:a\nb\r\n", "1# a => 1) a\nb\n"),
            ("%1\r\n+a\r\n*2\r\n*0\r\n*0\r\n", "1# a => \n   1) (empty array)\n   2) (empty array)\n"),
            ("%1\r\n+a\r\n*1\r\n*2\r\n:1\r\n:2\r\n", "1# a => \n   1) 1) (integer) 1\n      2) (integer) 2\n"),
            ("%1\r\n+a\r\n%1\r\n+b\r\n*2\r\n:1\r\n:2\r\n", "1# a => \n   1# b => \n      1) (integer) 1\n      2) (integer) 2\n"),
            ("%1\r\n+a\r\n*2\r\n%1\r\n+b\r\n*1\r\n:1\r\n:2\r\n", "1# a => \n   1) 1# b => 1) (integer) 1\n   2) (integer) 2\n"),
            ("%1\r\n+a\r\n*1\r\n%2\r\n+b\r\n:1\r\n+c\r\n:2\r\n", "1# a => \n   1) 1# b => (integer) 1\n      2# c => (integer) 2\n"),
            ("%2\r\n+a\r\n>2\r\n:1\r\n:2\r\n+b\r\n%0\r\n", "1# a => \n   1) (integer) 1\n   2) (integer) 2\n2# b => (empty hash)\n"),
            (
                "%2\r\n+a\r\n*1\r\n:1\r\n+bb\r\n*3\r\n:1\r\n:2\r\n*2\r\n:3\r\n:4\r\n",
                "1# a => 1) (integer) 1\n2# bb => \n   1) (integer) 1\n   2) (integer) 2\n   3) 1) (integer) 3\n      2) (integer) 4\n"
            )
        ]
        for (resp, expected) in cases { XCTAssertEqual(try format(resp), expected, resp.debugDescription) }
        let wide = "%10\r\n" + (0..<10).map { "+k\($0)\r\n*1\r\n:\($0)\r\n" }.joined()
        XCTAssertEqual(try format(wide), (0..<10).map { ($0 == 9 ? "" : " ") + "\($0 + 1)# k\($0) => 1) (integer) \($0)\n" }.joined())
    }
}

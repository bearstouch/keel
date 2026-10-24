import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// NFR-PF08's first half: a 10,000-element reply renders in under 500 ms. This times Keel's text for it (the
/// redis-cli formatting the console shows); the text view's own layout is checked by hand in the app.
final class ConsoleRenderPerformanceTests: XCTestCase {
    func testTenThousandElementReply() throws {
        // A `LRANGE`-like reply of mixed bulk strings, binary values that need escaping and nested pairs.
        let reply = RESPValue.array(
            (0..<10_000).map { i in
                switch i % 3 {
                case 0: .bulkString(Data("item:\(i):payload".utf8))
                case 1: .bulkString(Data([0x00, 0x7F, 0x0A]) + Data("bin\(i)".utf8))
                default: .array([.bulkString(Data("field\(i)".utf8)), .integer(Int64(i))])
                }
            })
        let clock = ContinuousClock()
        var runs: [Duration] = [], text = ""
        for _ in 0..<3 {
            let start = clock.now
            text = RedisCliFormatter.format(reply)
            runs.append(clock.now - start)
        }
        XCTAssertTrue(text.hasPrefix("    1) \"item:0:payload\"\n"), String(text.prefix(40)))
        XCTAssertTrue(text.contains("10000) "))
        let slowest = try XCTUnwrap(runs.max())
        print("Console 10,000-element reply: formatted in \(slowest) (max of \(runs.count))")
        BenchmarkRecorder.record("xctest.console_render_10k", slowest)
        XCTAssertLessThan(slowest, .milliseconds(500 * PerformanceBudget.slack))
    }
}

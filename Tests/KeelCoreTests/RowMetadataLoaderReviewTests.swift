import Foundation
import XCTest

@testable import KeelCore

final class RowMetadataLoaderReviewTests: XCTestCase {
    /// A server that fails every `TYPE`: one batch is sent, then the loader stops instead of re-sending every 100 ms.
    func testFailingBatchIsNotResentInALoop() async {
        let server = RecordingServer { arguments in arguments.first == "TYPE" ? "-ERR busy\r\n" : ":-1\r\n" }
        let index = KeyIndex(service: DataCommandService(session: server.session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        await index.ingest([Data("a".utf8), Data("b".utf8)])
        let sleeps = Counter()
        let loader = RowMetadataLoader(index: index, sleep: { _ in sleeps.increment() })
        let changed = await loader.load([0, 1])
        XCTAssertEqual(Set(changed), [0, 1], "the PTTLs that did answer are kept")
        let sent = server.allCommands.filter { $0.first != "HELLO" && $0.first != "CLIENT" && $0.first != "SELECT" }
        XCTAssertEqual(sent.filter { $0.first == "TYPE" }.count, 2)
        XCTAssertEqual(sent.filter { $0.first == "PTTL" }.count, 2)
        XCTAssertEqual(sleeps.value, 0)
        let row = await index.metadata(at: 0)
        XCTAssertEqual(row.type, .unknown)
        XCTAssertEqual(row.expiry, .persistent)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    func testSizeTableIsBounded() async {
        let index = KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        let count = KeyIndex.sizeTableLimit + 1
        await index.ingest((0..<count).map { Data("k\($0)".utf8) })
        let generation = await index.generation
        _ = await index.applyMetadata((0..<count).map { RowMetadataResult(index: $0, size: .bytes(10)) }, generation: generation)
        // The table started over at the limit: the last key keeps its size, earlier ones read as unknown again.
        let last = await index.metadata(at: count - 1).size
        XCTAssertEqual(last, .bytes(10))
        let first = await index.metadata(at: 0).size
        XCTAssertEqual(first, .unknown)
    }
}

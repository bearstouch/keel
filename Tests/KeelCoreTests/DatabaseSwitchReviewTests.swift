import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review-driven KEEL-025 cases: answers that land after a switch or a removal while they were in flight.
final class DatabaseSwitchReviewTests: XCTestCase {
    /// db0's replies wait for `release()`; db3 answers at once. Both list the same key, so a stale answer could match it.
    private func splitIndex(db0: GatedTransport, db3: RecordingTransport) -> KeyIndex {
        let session = ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: database == 0 ? db0 : db3)
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake connect failed", suggestion: "")
            }
            return connection
        }
        return KeyIndex(service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
    }

    private func waitForCommands(_ transport: RecordingTransport, _ count: Int) async {
        var spins = 0
        while transport.commands.count < count, spins < 100_000 { await Task.yield(); spins += 1 }
        XCTAssertEqual(transport.commands.count, count)
    }

    func testPresenceLandingAfterASwitchLeavesTheNewDatabaseAlone() async {
        let db0 = GatedTransport { $0.first == "SCAN" ? ScanServer.reply(cursor: 0, keys: ["k"]) : "+none\r\n" }
        let db3 = RecordingTransport { $0.first == "SCAN" ? ScanServer.reply(cursor: 0, keys: ["k"]) : "+string\r\n" }
        let index = splitIndex(db0: db0, db3: db3)
        db0.release()
        await index.loadMore()

        // TYPE k goes to db0 and is still out when the user switches to db3, which also has a "k".
        let check = Task { await index.presence(of: Data("k".utf8)) }
        await waitForCommands(db0.inner, 2)
        await index.switchDatabase(3)
        await index.loadMore()
        db0.release()
        let presence = await check.value
        XCTAssertEqual(presence, .missing, "the answer is about db0's key")
        let metadata = await index.metadata(at: 0)
        XCTAssertFalse(metadata.isStale, "db3's row isn't marked gone by db0's answer")
        XCTAssertEqual(metadata.expiry, .unknown)
        XCTAssertEqual(db0.inner.commands.map(\.first), ["SCAN", "TYPE"])
        XCTAssertEqual(db3.commands.map(\.first), ["SCAN"])
    }

    func testRemovalWhileAPageIsInFlightKeepsTheIndexConsistent() async {
        let pages = [keys("a", 0..<3), keys("b", 0..<3)]
        let gate = GatedTransport { arguments in
            guard arguments.first == "SCAN", let cursor = Int(arguments[1]), pages.indices.contains(cursor) else { return "-ERR unexpected\r\n" }
            return ScanServer.reply(cursor: cursor + 1 == pages.count ? 0 : cursor + 1, keys: pages[cursor])
        }
        let index = splitIndex(db0: gate, db3: RecordingTransport())
        gate.release()
        await index.loadMore()
        let generation = await index.generation

        let page = Task { await index.loadMore() }
        await waitForCommands(gate.inner, 2)
        let removed = await index.remove(key: Data("a:1".utf8))
        XCTAssertTrue(removed)
        gate.release()
        let status = await page.value
        XCTAssertEqual(status.phase, .complete, "the page in flight still lands: a removal isn't a restart")
        XCTAssertEqual(status.loadedCount, 5)

        // Every key is found at its own index, and the tree counts what is loaded.
        let loaded = await index.keys(in: 0..<10)
        XCTAssertEqual(loaded.map { String(decoding: $0, as: UTF8.self) }, ["a:0", "a:2", "b:0", "b:1", "b:2"])
        for (offset, key) in loaded.enumerated() {
            let found = await index.index(of: key)
            XCTAssertEqual(found, offset)
        }
        let rootCount = await index.namespaceKeyCount(of: .root)
        XCTAssertEqual(rootCount, 5)
        let after = await index.generation
        XCTAssertEqual(after, generation + 1, "only the removal moved indices")
    }
}

final class RecreatedKeyReviewTests: XCTestCase {
    func testRecreatedKeyIsNoLongerGone() async throws {
        let fake = FakeKeyspace([0: ["k": "string"]])
        let index = fake.index()
        await index.loadMore()
        await index.updateMetadata(at: 0) {
            $0.expiry = .gone; $0.isStale = true
        }
        let presence = await index.presence(of: Data("k".utf8))
        XCTAssertEqual(presence, .exists(.string))
        let metadata = await index.metadata(at: 0)
        XCTAssertEqual(metadata.expiry, .unknown, "its TTL is fetched again")
        XCTAssertFalse(metadata.isStale)
    }
}

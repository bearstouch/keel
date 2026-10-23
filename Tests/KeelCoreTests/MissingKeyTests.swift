import Foundation
import XCTest

@testable import KeelCore

final class MissingKeyTests: XCTestCase {
    func testReportsAndOffersRemoval() async throws {
        let fake = FakeKeyspace([0: ["user:1": "hash", "user:2": "string", "user:3": "list", "health": "string"]])
        let index = fake.index()
        await index.loadMore()
        let gone = Data("user:2".utf8)
        let found = await index.index(of: gone)
        let removedAt = try XCTUnwrap(found)

        // Another client deletes the key; opening it reports it missing and marks the row stale (it reads "expired").
        fake.delete("user:2")
        let afterDelete = await index.presence(of: gone)
        XCTAssertEqual(afterDelete, .missing)
        XCTAssertEqual(KeyPresence.missingMessage, "Key no longer exists")
        let stale = await index.metadata(at: removedAt)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.expiry, .gone)
        XCTAssertEqual(fake.commands("TYPE"), [["TYPE", "user:2"]])
        // A key that still exists reports its current type.
        let stillThere = await index.presence(of: Data("user:3".utf8))
        XCTAssertEqual(stillThere, .exists(.list))

        // Remove from List: only the list changes, nothing is sent, later keys move up and keep their metadata.
        let sent = fake.commands.count
        let generation = await index.generation
        await index.updateMetadata(at: removedAt + 1) { $0.size = .bytes(512) }
        let next = await index.key(at: removedAt + 1)
        let removed = await index.remove(key: gone)
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.commands.count, sent)
        let remaining = await index.count
        XCTAssertEqual(remaining, 3)
        let removedIndex = await index.index(of: gone)
        XCTAssertNil(removedIndex)
        let nextIndex = await index.index(of: next)
        XCTAssertEqual(nextIndex, removedAt)
        let movedSize = await index.metadata(at: removedAt).size
        XCTAssertEqual(movedSize, .bytes(512))
        let newGeneration = await index.generation
        XCTAssertNotEqual(newGeneration, generation, "the list re-reads rows whose indices moved")
        let users = await index.namespaceEntries(index.namespaceChildren(of: .root))
        XCTAssertEqual(users.first { $0.name == Data("user".utf8) }?.keyCount, 2, "the tree counts drop with it")
        let removedAgain = await index.remove(key: gone)
        XCTAssertFalse(removedAgain, "removing twice does nothing")
        let stillListed = await index.contains(gone)
        XCTAssertFalse(stillListed)
    }

    func testCheckFailureLeavesTheKeyAlone() async throws {
        let index = offlineCoreIndex()
        await index.ingest([Data("k".utf8)])
        guard case .failed(let error) = await index.presence(of: Data("k".utf8)) else { return XCTFail("an unreachable server isn't a missing key") }
        XCTAssertEqual(error.code, "CONNECTION_FAILED")
        let markedStale = await index.metadata(at: 0).isStale
        XCTAssertFalse(markedStale)
    }

    func testRemovalDuringAScanKeepsTheScanGoing() async throws {
        let fake = ScanServer(pages: [keys("a", 0..<3), keys("a", 3..<6)])
        let index = fake.index()
        await index.loadMore()
        let removed = await index.remove(key: Data("a:1".utf8))
        XCTAssertTrue(removed)
        let status = await index.loadMore()
        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(status.loadedCount, 5)
        XCTAssertEqual(fake.scans.map { $0[1] }, ["0", "1"], "removal doesn't move the cursor")
    }
}

/// An index whose server is never reachable.
func offlineCoreIndex() -> KeyIndex {
    let session = ServerSession(open: { _, _ throws(ConnectionFailure) in
        throw ConnectionFailure(category: .connectionRefused, message: "offline", suggestion: "")
    })
    return KeyIndex(service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
}

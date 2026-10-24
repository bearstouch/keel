import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class KeyActionsReviewTests: XCTestCase {
    /// A rename onto a loaded key (the one it replaced) must not keep that key's TTL, size or "expired" mark: the row
    /// is another value now and its metadata is read again.
    func testAddOntoLoadedKeyResetsItsMetadata() async {
        let index = KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: false)))
        let target = Data("user:2".utf8)
        await index.ingest([Data("user:1".utf8), target])
        let row = await index.index(of: target)!
        await index.updateMetadata(at: row) { $0 = KeyMetadata(type: .hash, isStale: true, expiry: .gone, size: .bytes(4_096)) }
        let generation = await index.generation

        let added = await index.add(key: target, type: .string)
        XCTAssertTrue(added)
        let metadata = await index.metadata(at: row)
        XCTAssertEqual(metadata, KeyMetadata(type: .string))
        // Answers read for the replaced key before the rename are dropped.
        let after = await index.generation
        XCTAssertNotEqual(after, generation)
    }
}

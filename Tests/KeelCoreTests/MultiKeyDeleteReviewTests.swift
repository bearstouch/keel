import Foundation
import XCTest

@testable import KeelCore

/// Review extras for KEEL-038: the index after a multi-key removal, and the generation guard on selections.
final class MultiKeyDeleteReviewTests: XCTestCase {
    private func names(_ index: KeyIndex) async -> [String] { await index.keys(in: 0..<index.count).map { String(decoding: $0, as: UTF8.self) } }

    func testRemovingSeveralKeysKeepsEveryOtherKeyItsMetadataAndTheTree() async {
        let index = offlineCoreIndex()
        await index.ingest(["user:1", "user:2", "order:1", "user:3", "order:2", "cache"].map { Data($0.utf8) })
        // Sizes and types on keys before, between and after the removed ones move with their key.
        await index.updateMetadata(at: 0) { $0.size = .bytes(10) }
        await index.updateMetadata(at: 2) {
            $0.size = .bytes(20); $0.type = .hash
        }
        await index.updateMetadata(at: 5) { $0.size = .bytes(50) }
        let before = await index.generation
        let removed = await index.remove(keys: ["user:2", "user:3", "missing", "user:2"].map { Data($0.utf8) })
        XCTAssertEqual(removed, 2, "keys not loaded and repeats are skipped")
        let remaining = await names(index)
        XCTAssertEqual(remaining, ["user:1", "order:1", "order:2", "cache"])
        for (offset, name) in remaining.enumerated() {
            let found = await index.index(of: Data(name.utf8))
            XCTAssertEqual(found, offset, name)
        }
        let sizes = await [0, 1, 2, 3].asyncMap { await index.metadata(at: $0).size }
        XCTAssertEqual(sizes, [.bytes(10), .bytes(20), .unknown, .bytes(50)])
        let type = await index.metadata(at: 1).type
        XCTAssertEqual(type, .hash)
        let entries = await index.namespaceEntries(index.namespaceChildren(of: .root))
        XCTAssertEqual(entries.first { $0.name == Data("user".utf8) }?.keyCount, 1)
        XCTAssertEqual(entries.first { $0.name == Data("order".utf8) }?.keyCount, 2)
        let after = await index.generation
        XCTAssertEqual(after, before + 1)
        // Nothing loaded among them: no rebuild, and indices keep their meaning.
        let none = await index.remove(keys: [Data("missing".utf8)])
        XCTAssertEqual(none, 0)
        let unchanged = await index.generation
        XCTAssertEqual(unchanged, after)
    }

    func testSelectionIndicesFromAnEarlierGenerationNameNoKeys() async {
        let index = offlineCoreIndex()
        await index.ingest(["a", "b", "c", "d"].map { Data($0.utf8) })
        let generation = await index.generation
        let picked = await index.keys(at: [1, 3, 9], generation: generation)
        XCTAssertEqual(picked, [Data("b".utf8), Data("d".utf8)])
        // After a removal, index 1 is "c": a selection taken before must not name it.
        await index.remove(key: Data("a".utf8))
        let stale = await index.keys(at: [1, 3], generation: generation)
        XCTAssertNil(stale)
        let current = await index.generation
        await index.restart()
        let afterRestart = await index.keys(at: [0], generation: current)
        XCTAssertNil(afterRestart)
    }
}

extension Array {
    fileprivate func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}

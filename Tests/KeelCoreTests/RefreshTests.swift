import Foundation
import XCTest

@testable import KeelCore

final class RefreshTests: XCTestCase {
    func testKeepsFilterAndSelection() async throws {
        let fake = FakeKeyspace([0: ["user:1": "hash", "user:2": "hash", "user:3": "string", "order:1": "hash"]])
        let index = fake.index(filter: KeyFilter(pattern: "user:*", type: .hash))
        await index.loadMore()
        let selected = Data("user:2".utf8)
        let selectedBefore = await index.index(of: selected)
        XCTAssertNotNil(selectedBefore)
        let sizeBefore = try await index.databaseSize().get()
        XCTAssertEqual(sizeBefore, 4)

        // Another client adds a key; Refresh restarts with the same filter, shows it and DBSIZE counts it (AC2).
        fake.set("user:0", type: "hash")
        await index.restart()
        let selectedDuringRestart = await index.index(of: selected)
        XCTAssertNil(selectedDuringRestart, "the restart clears the loaded keys")
        await index.loadMore()
        XCTAssertEqual(fake.commands("SCAN").last, ["SCAN", "0", "MATCH", "user:*", "COUNT", "1000", "TYPE", "hash"])
        let keptFilter = await index.configuration.filter
        XCTAssertEqual(keptFilter, KeyFilter(pattern: "user:*", type: .hash))
        let loaded = await index.keys(in: 0..<10).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(loaded, ["user:0", "user:1", "user:2"])
        let sizeAfter = try await index.databaseSize().get()
        XCTAssertEqual(sizeAfter, 5)
        // The selected key is found again by its bytes, at its new position.
        let selectedAfter = await index.index(of: selected)
        XCTAssertEqual(selectedAfter, 2)
        XCTAssertFalse(fake.commands.contains { $0.first == "KEYS" })
    }

    func testSwitchDatabaseKeepsFilterAndClearsTheList() async throws {
        let fake = FakeKeyspace([0: ["a:1": "string", "a:2": "string"], 3: ["a:9": "string", "b:1": "string"]])
        let index = fake.index(filter: KeyFilter(pattern: "a:*"))
        await index.loadMore()
        let countBefore = await index.count
        XCTAssertEqual(countBefore, 2)

        await index.switchDatabase(3)
        let countAfterSwitch = await index.count
        XCTAssertEqual(countAfterSwitch, 0, "switching clears the list at once")
        let database = await index.context.database
        XCTAssertEqual(database, 3)
        await index.loadMore()
        let loaded = await index.keys(in: 0..<10).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(loaded, ["a:9"])
        let switchedSize = try await index.databaseSize().get()
        XCTAssertEqual(switchedSize, 2)
        XCTAssertEqual(fake.server.opened.map(\.role), [.browser(database: 0), .browser(database: 3)])
    }
}

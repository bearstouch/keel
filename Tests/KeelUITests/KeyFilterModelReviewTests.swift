import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

final class KeyFilterModelReviewTests: XCTestCase {
    /// A restart followed by more keys than before, all before the list reloads, must still drop the old matches.
    @MainActor func testRestartWithMoreKeysBeforeReloadStartsTheLocalSearchOver() async {
        let list = await keyList(["user:1", "session:a", "USER:2"], mode: .flat)
        await list.setLocalFilter("user")
        XCTAssertEqual(list.visibleRowCount, 2)
        await list.index.restart()
        await list.index.ingest(["a", "b", "c", "user:x", "d", "e"].map { Data($0.utf8) })
        await list.reload()
        await list.fetchVisibleContent()
        XCTAssertEqual(list.names, ["user:x"])
    }

    /// A search started after a restart but before the reload has fewer keys than rows: it stops instead of spinning.
    @MainActor func testSearchAfterAnUnreloadedRestartEnds() async {
        let list = await keyList(["user:1", "session:a", "USER:2"], mode: .flat)
        await list.index.restart()
        await list.setLocalFilter("user")
        XCTAssertEqual(list.visibleRowCount, 0)
        await list.reload()
        XCTAssertEqual(list.visibleRowCount, 0)
    }
}

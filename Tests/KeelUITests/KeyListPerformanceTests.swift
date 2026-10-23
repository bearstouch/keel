import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// FR-KB04 / NFR-PF02 proxies for the key list itself, with 1M loaded keys: filling the rows of a scrolled-to page
/// stays under one 60 Hz frame. Expanding a 500,000-key folder is guarded at 500 ms, not FR-KB04's 200 ms:
/// `NSOutlineView.expandItem` alone takes ~0.3 s for that many children (our callbacks ~40 ms), a known gap recorded in
/// KEEL-022. Instruments' Animation Hitches on a real window (AC1) is the actual acceptance check and stays manual. Budgets hold in optimized
/// builds (`swift test -c release -Xswiftc -enable-testing`); debug builds only guard against gross regressions.
final class KeyListPerformanceTests: XCTestCase {
    #if DEBUG
        static let slack = 5.0
    #else
        static let slack = 1.0
    #endif

    @MainActor func testOneMillionKeysExpandAndScrollUnderBudget() async throws {
        let index = offlineIndex()
        // Scrambled the way SCAN returns them: 500k under `session`, 500k spread over 1,000 `user` folders.
        await index.ingest(
            (0..<1_000_000).map { step in
                let i = step * 7_919 % 1_000_000
                return Data((i.isMultiple(of: 2) ? String(format: "session:%08d:token", i) : String(format: "user:%04d:%08d", i % 1_000, i)).utf8)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let clock = ContinuousClock()

        for mode in [KeyListDataSource.Mode.tree, .flat] {
            let list = KeyListDataSource(index: index, mode: mode)
            window.contentView = list.scrollView
            list.scrollView.frame = window.contentView!.bounds
            await list.reload()
            await list.fetchVisibleContent()

            if mode == .tree {
                let start = clock.now
                try await list.expand(named: "session")
                let expand = clock.now - start
                print("KeyList expand 500,000 children: \(expand)")
                XCTAssertEqual(list.visibleRowCount, 500_002)
                XCTAssertLessThan(expand, .milliseconds(500 * Self.slack))
            } else {
                XCTAssertEqual(list.visibleRowCount, 1_000_000)
            }

            // Jump deep into the list, as a fast scroll does, and fill the newly visible rows.
            var fills: [Duration] = []
            for target in stride(from: 100_000, to: 500_000, by: 100_000) {
                list.activeView.scrollRowToVisible(target)
                // AppKit's own tiling after the jump isn't the fill's cost; let it settle first.
                list.scrollView.layoutSubtreeIfNeeded()
                _ = await index.count
                let start = clock.now
                await list.fetchVisibleContent()
                fills.append(clock.now - start)
                XCTAssertNotNil(list.row(at: target), "\(mode) row \(target) has no content")
            }
            let slowest = try XCTUnwrap(fills.max())
            print("KeyList \(mode) fill after scroll: \(slowest) (max of \(fills.count))")
            XCTAssertLessThan(slowest, .milliseconds(16 * Self.slack))
        }
    }
}

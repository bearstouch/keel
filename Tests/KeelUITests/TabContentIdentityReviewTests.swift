import AppKit
import SwiftUI
import XCTest

@testable import KeelCore
@testable import KeelUI

/// Switching between two connected tabs in the same mode shows the selected tab's own console and key list: their
/// AppKit views belong to each tab's models, so a reused view would send typed commands to the other tab's server.
final class TabContentIdentityReviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-tab-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// Two connected tabs (A selected) in `mode`, hosted in an on-screen window.
    @MainActor private func twoTabs(mode: TabMode) async throws -> (ScreenHost, ConnectionTabs, TabSession, TabSession) {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        let one = try await store.create(ConnectionSettings(name: "one"))
        let two = try await store.create(ConnectionSettings(name: "two"))
        let app = AppModel(profiles: store, connector: FakeConnector(), persistence: Persistence(directory: directory, debounce: .zero))
        await app.restore()
        let window = try XCTUnwrap(app.windows.first)
        let sidebar = SidebarModel(store: store, tabs: window, copy: { _ in })
        await sidebar.reload()
        let a = window.open(profileID: one.id, database: 0)
        let b = window.open(profileID: two.id, database: 0, newTab: true)
        for tab in [a, b] {
            window.selectedID = tab.id; window.setMode(mode)
            app.connectIfNeeded(tab.id)
            for _ in 0..<200 where app.session(tab.id)?.status != .connected { try await Task.sleep(for: .milliseconds(5)) }
            if mode == .console { app.session(tab.id)?.openConsole() }
        }
        window.selectedID = a.id
        let screen = ScreenHost(WindowContent(sidebar: sidebar, tabs: window))
        await screen.settle(0.3)
        return (screen, window, try XCTUnwrap(app.session(a.id)), try XCTUnwrap(app.session(b.id)))
    }

    @MainActor func testSwitchingConsoleTabsShowsTheSelectedTabsConsole() async throws {
        let (screen, window, a, b) = try await twoTabs(mode: .console)
        defer { screen.close() }
        let consoleA = try XCTUnwrap(a.console), consoleB = try XCTUnwrap(b.console)
        XCTAssertTrue(consoleA.scrollView.window === screen.window, "tab A's console is on screen")

        window.selectedID = b.id
        await screen.settle(0.3)
        XCTAssertTrue(consoleB.scrollView.window === screen.window, "tab B's console replaces A's")
        XCTAssertNil(consoleA.scrollView.window, "tab A's console is gone, so typing can't reach A's server")
        XCTAssertTrue(consoleB.textView?.model === consoleB)

        window.selectedID = a.id
        await screen.settle(0.3)
        XCTAssertTrue(consoleA.scrollView.window === screen.window)
        XCTAssertNil(consoleB.scrollView.window)
    }

    @MainActor func testSwitchingBrowserTabsShowsTheSelectedTabsKeyList() async throws {
        let (screen, window, a, b) = try await twoTabs(mode: .browser)
        defer { screen.close() }
        let listA = try XCTUnwrap(a.browser?.list), listB = try XCTUnwrap(b.browser?.list)
        XCTAssertTrue(listA.scrollView.window === screen.window)

        window.selectedID = b.id
        await screen.settle(0.3)
        XCTAssertTrue(listB.scrollView.window === screen.window, "tab B's key list replaces A's")
        XCTAssertNil(listA.scrollView.window)
    }

    /// A reused host swaps in the new model's view; a tab moved to another window keeps its view there when the old
    /// window's host goes away.
    @MainActor func testContainerSwapsViewsAndNeverTakesBackAMovedView() {
        let first = ModelViewContainer(), second = ModelViewContainer()
        let a = NSScrollView(), b = NSScrollView()
        XCTAssertTrue(first.show(a))
        XCTAssertFalse(first.show(a), "already shown")
        XCTAssertTrue(first.show(b))
        XCTAssertNil(a.superview, "the previous model's view leaves")
        XCTAssertTrue(b.superview === first)

        XCTAssertTrue(second.show(b))
        first.release()
        XCTAssertTrue(b.superview === second, "the old host's teardown leaves the moved view alone")
        second.release()
        XCTAssertNil(b.superview)
    }
}

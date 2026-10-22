import AppKit
import SwiftUI
import XCTest
@testable import KeelUI

final class RootViewTests: XCTestCase {
    @MainActor func testEmptyStateIsDescribedForVoiceOver() {
        _ = RootView().body  // Building the body must not trap outside a running app.
        XCTAssertEqual(RootView.accessibilityLabel, "Keel, no connections yet")
    }
}

final class MainWindowTests: XCTestCase {
    @MainActor func testMainWindowIsTitledKeelAndHostsRootView() {
        let window = MainWindow.make()
        XCTAssertEqual(window.title, "Keel")
        XCTAssertEqual(window.minSize, MainWindow.minimumSize)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView is NSHostingView<RootView>)
    }
}

import Foundation
import KeelRESP
import XCTest

@testable import KeelCore
@testable import KeelUI

/// FR-KB02 from the browser: the ⋯ menu's Auto-page, Pause and Resume, and the footer's links in either mode.
final class BrowserPagingTests: XCTestCase {
    /// `pages` SCAN pages of `perPage` keys: cursor n answers page n and points at n + 1, the last one at 0.
    @MainActor private func browser(pages: Int, perPage: Int = 1, limit: Int = KeyIndexConfiguration.defaultLimit) async -> (BrowserModel, KeyListDataSource) {
        let all = (0..<pages).map { page in (0..<perPage).map { "k:\(page * perPage + $0)" } }
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(
                transport: FakeTransport { arguments in
                    switch arguments.first {
                    case "SCAN":
                        guard let cursor = Int(arguments[1]), all.indices.contains(cursor) else { return "-ERR bad cursor\r\n" }
                        let next = String(cursor + 1 == all.count ? 0 : cursor + 1)
                        return "*2\r\n$\(next.utf8.count)\r\n\(next)\r\n*\(all[cursor].count)\r\n" + all[cursor].map { "$\($0.utf8.count)\r\n\($0)\r\n" }.joined()
                    case "DBSIZE": return ":\(pages * perPage)\r\n"
                    case "TYPE": return "+string\r\n"
                    default: return "-ERR unexpected\r\n"
                    }
                })
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake", suggestion: "")
            }
            return connection
        }
        let index = KeyIndex(
            service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "local", readOnly: true)),
            configuration: KeyIndexConfiguration(pageSize: perPage, limit: limit))
        let list = KeyListDataSource(index: index, mode: .flat)
        let model = BrowserModel(list: list, filter: KeyFilterModel(list: list), database: 0)
        await model.start()
        return (model, list)
    }

    @MainActor func testAutoPageLoadsEveryPageAndLoadMoreGoesBackToManual() async {
        let (model, list) = await browser(pages: 30)
        XCTAssertEqual(list.keyCountForTests, 1, "a new tab loads one page")
        XCTAssertEqual(list.pagingStatus.mode, .manual)

        await model.page(.autoPage(true))
        XCTAssertEqual(list.keyCountForTests, 30)
        XCTAssertEqual(list.footer.text, "All keys loaded")
        XCTAssertEqual(list.pagingStatus.mode, .auto)

        // Refresh and a filter change keep Auto-page: every page loads again, not just the first.
        await model.refresh()
        XCTAssertEqual(list.keyCountForTests, 30)
        await model.filter?.setType(.string)
        XCTAssertEqual(list.keyCountForTests, 30)
        XCTAssertEqual(list.pagingStatus.mode, .auto)

        // Load more is manual paging: one page, and the menu's Auto-page is off again.
        await model.refresh()
        await model.page(.autoPage(false))
        XCTAssertEqual(list.pagingStatus.mode, .manual)
        await model.refresh()
        XCTAssertEqual(list.keyCountForTests, 1)
        await model.perform(.loadMore)
        XCTAssertEqual(list.keyCountForTests, 2)
        XCTAssertEqual(list.pagingStatus.mode, .manual)
    }

    @MainActor func testAutoPageStopsAtTheLimitAndContinueKeepsPaging() async {
        let (model, list) = await browser(pages: 6, perPage: 10, limit: 25)
        await model.page(.autoPage(true))
        XCTAssertEqual(list.keyCountForTests, 25)
        XCTAssertEqual(list.footer.text, "25 of 60 keys loaded · Limit reached · Continue")

        await model.perform(.continue)
        XCTAssertEqual(list.keyCountForTests, 50, "Continue raises the limit once and auto-pages up to it")
        await model.perform(.continue)
        XCTAssertEqual(list.keyCountForTests, 60)
        XCTAssertEqual(list.footer.text, "All keys loaded")
    }

    @MainActor func testPauseStopsAfterThePageInFlightAndResumeFinishes() async {
        let (model, list) = await browser(pages: 2_000)
        let run = Task { await model.page(.autoPage(true)) }
        while await list.index.count < 3 { await Task.yield() }
        await model.page(.pause)
        await run.value
        let paused = await list.index.status
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertLessThan(paused.loadedCount, 2_000)
        XCTAssertEqual(list.footer.notice, "Paused")
        XCTAssertEqual(list.keyCountForTests, paused.loadedCount, "the list shows what was loaded")

        await model.page(.resume)
        XCTAssertEqual(list.keyCountForTests, 2_000)
        XCTAssertEqual(list.footer.text, "All keys loaded")
    }

    @MainActor func testHiddenListStopsAutoPageAndShowingItResumes() async {
        let (model, list) = await browser(pages: 2_000)
        let run = Task { await model.page(.autoPage(true)) }
        while await list.index.count < 3 { await Task.yield() }
        await model.setListShown(false)
        await run.value
        let stopped = await list.index.status
        XCTAssertLessThan(stopped.loadedCount, 2_000)
        XCTAssertEqual(stopped.mode, .auto, "hiding isn't pausing: the mode stays")
        // Nothing scans while hidden.
        await model.page(.autoPage(true))
        let hidden = await list.index.count
        XCTAssertEqual(hidden, stopped.loadedCount)

        await model.setListShown(true)
        XCTAssertEqual(list.keyCountForTests, 2_000)
    }
}

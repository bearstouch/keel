import AppKit
import XCTest

@testable import KeelCore
@testable import KeelUI

/// The shared typed-confirmation sheet (FR-SF03) and the browser's multi-key delete behind it (FR-KB11, FR-SF04).
final class TypedConfirmationTests: XCTestCase {
    private let staging = SafetyProfile(name: "api-staging", readOnly: false, production: false, server: "10.0.0.5:6379")
    private let production = SafetyProfile(name: "payments-prod", readOnly: false, production: true, server: "cache.internal:6379")

    @MainActor private final class Calls { var count = 0 }

    @MainActor private func model(_ operation: TypedConfirmation.Operation, profile: SafetyProfile? = nil, database: Int = 3, calls: Calls) -> TypedConfirmationModel {
        TypedConfirmationModel(TypedConfirmation(operation: operation, profile: profile ?? staging, database: database)) {
            calls.count += 1
            return nil
        }
    }

    // MARK: - Story tests

    @MainActor func testExactMatchRequired() async {
        let calls = Calls()
        // AC1: case and whitespace count, for each kind of typed text.
        let cases: [(TypedConfirmation.Operation, String, [String])] = [
            (.deleteKeys(count: 2_000), "2000", ["2,000", " 2000", "2000 ", "200"]),
            (.flushDatabase(3), "db3", ["Db3", "DB3", "db 3", "db3\n", "3"]),
            (.flushAll, "api-staging", ["API-staging", "api-staging ", "api"]),
            (.deletePattern(Data("tmp:*".utf8)), "tmp:*", ["tmp:", "TMP:*", "tmp:* "])
        ]
        for (operation, exact, near) in cases {
            let sheet = model(operation, calls: calls)
            XCTAssertFalse(sheet.canConfirm, "empty field for \(exact)")
            for text in near {
                sheet.typed = text
                XCTAssertFalse(sheet.canConfirm, "\(text.debugDescription) must not confirm \(exact)")
                let confirmed = await sheet.confirm()
                XCTAssertFalse(confirmed)
            }
            sheet.typed = exact
            XCTAssertTrue(sheet.canConfirm, exact)
            XCTAssertEqual(sheet.confirmation.prompt, "Type \(exact) to confirm.")
        }
        XCTAssertEqual(calls.count, 0, "a near match never runs the action")
        let sheet = model(.flushDatabase(3), calls: calls)
        sheet.typed = "db3"
        let confirmed = await sheet.confirm()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor func testReturnDoesNotConfirm() async {
        let calls = Calls()
        let sheet = model(.deleteKeys(count: 3), calls: calls)
        sheet.typed = "3"
        XCTAssertTrue(sheet.canConfirm)
        // Return in the field (its onSubmit) never runs the action, even with the exact text typed.
        sheet.submit()
        sheet.submit()
        await Task.yield()
        XCTAssertEqual(calls.count, 0)
    }

    @MainActor func testProductionSheetNamesTheServer() {
        // AC3: on Production the sheet names the server; elsewhere it doesn't.
        let prod = TypedConfirmation(operation: .flushAll, profile: production, database: 0)
        XCTAssertEqual(prod.serverLine, "Server: cache.internal:6379")
        XCTAssertEqual(prod.expectedText, "payments-prod")
        XCTAssertNil(TypedConfirmation(operation: .flushAll, profile: staging, database: 0).serverLine)
        // Through the policy's request too (the console's FLUSHDB).
        let request = ConfirmationRequest(operation: .flushDatabase(3), typedText: "db3", message: "")
        XCTAssertEqual(TypedConfirmation(request, profile: production, database: 3)?.serverLine, "Server: cache.internal:6379")
        XCTAssertNil(TypedConfirmation(ConfirmationRequest(operation: .keys, typedText: nil, message: ""), profile: production, database: 0))
    }

    @MainActor func testFailedActionIsNotOfferedAgain() async {
        var runs = 0
        let sheet = TypedConfirmationModel(TypedConfirmation(operation: .deleteKeys(count: 2), profile: staging, database: 0)) {
            runs += 1
            return "Deleted 0 of 2 keys."
        }
        sheet.typed = "2"
        let first = await sheet.confirm()
        XCTAssertFalse(first)
        XCTAssertEqual(sheet.failure, "Deleted 0 of 2 keys.")
        // Part of it may have run: the same yes isn't offered again.
        XCTAssertFalse(sheet.canConfirm)
        let second = await sheet.confirm()
        XCTAssertFalse(second)
        XCTAssertEqual(runs, 1)
    }

    // MARK: - Browser multi-key delete

    @MainActor private func browser(_ keys: Set<String>, readOnly: Bool = false) async -> (BrowserModel, KeyListDataSource, BrowserKeyspace) {
        let server = BrowserKeyspace([0: keys])
        let list = server.list(readOnly: readOnly); list.tableView.frame.size.height = 600
        await list.setMode(.flat)
        let model = BrowserModel(list: list, database: 0)
        await model.start()
        return (model, list, server)
    }

    @MainActor func testDeletingSelectedKeysAsksForTheCountAndRemovesThem() async throws {
        let (model, list, server) = await browser(["a", "b", "c", "d"])
        // Rows are sorted by the fake's SCAN: a, b, c, d. Select b, c and d.
        list.tableView.selectRowIndexes([1, 2, 3], byExtendingSelection: false)
        XCTAssertEqual(list.selectedKeys, [1, 2, 3])
        XCTAssertNil(list.selectedKey)
        await model.requestDeleteSelection()
        let sheet = try XCTUnwrap(model.deleteConfirmation)
        XCTAssertEqual(sheet.confirmation.expectedText, "3")
        XCTAssertEqual(sheet.listed, ["b", "c", "d"])
        // Nothing is sent before the typed confirmation.
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "UNLINK" })
        sheet.typed = "3"
        let confirmed = await sheet.confirm()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(server.commands.filter { $0.arguments.first == "UNLINK" }.map(\.arguments), [["UNLINK", "b", "c", "d"]])
        XCTAssertEqual(list.keyCountForTests, 1)
        XCTAssertEqual(list.totalKeys, 1)
        XCTAssertTrue(list.selectedKeys.isEmpty)
    }

    @MainActor func testDeleteKeyPressOpensTheSheet() async throws {
        let (model, list, _) = await browser(["a", "b"])
        list.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        XCTAssertTrue(list.handlesDelete(event))
        for _ in 0..<200 where model.deleteConfirmation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.deleteConfirmation?.confirmation.expectedText, "2")
        // One row: ⌫ goes to the view as before.
        list.tableView.selectRowIndexes([0], byExtendingSelection: false)
        XCTAssertFalse(list.handlesDelete(event))
    }

    @MainActor func testReadOnlyNeverAsks() async {
        let (model, list, server) = await browser(["a", "b"], readOnly: true)
        list.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        await model.requestDeleteSelection()
        XCTAssertNil(model.deleteConfirmation)
        XCTAssertFalse(server.commands.contains { $0.arguments.first == "UNLINK" })
    }
}

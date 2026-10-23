import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

final class ProfileTransferModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private static func makeStore(in directory: URL) async -> ProfileStore {
        let store = ProfileStore(directory: directory, secrets: MemorySecretStore())
        _ = await store.load()
        return store
    }

    @MainActor func testExportThenImportPreviewsAndAppliesThePolicy() async throws {
        let source = await Self.makeStore(in: directory.appendingPathComponent("a"))
        let folder = try await source.createFolder(named: "Payments")
        _ = try await source.create(ConnectionSettings(name: "payments-prod", label: .red), folderID: folder.id, password: Data("pw".utf8))
        let file = directory.appendingPathComponent("export.json")
        let exporter = ProfileTransferModel(store: source, chooseImport: { nil }, chooseExport: { file })
        await exporter.exportConnections()
        XCTAssertNil(exporter.message)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("hasPassword"))

        // Into the same store: everything collides, so the preview says so and Skip is preselected.
        let importer = ProfileTransferModel(store: source, chooseImport: { file }, chooseExport: { nil })
        await importer.beginImport()
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertEqual(importer.policy, .skip)
        XCTAssertEqual(ProfileTransferModel.contents(pending.preview), "1 connection and 1 folder.")
        XCTAssertEqual(ProfileTransferModel.conflicts(pending.preview), "2 already exist: “payments-prod”, “Payments”.")
        let before = await source.document
        await importer.confirmImport()
        XCTAssertNil(importer.pending)
        XCTAssertEqual(importer.message, "Nothing changed: everything in the file is already saved.")
        let after = await source.document
        XCTAssertEqual(after, before)

        // Keep both adds a copy.
        await importer.beginImport()
        importer.policy = .keepBoth
        await importer.confirmImport()
        XCTAssertEqual(importer.message, "Added 1 connection. Passwords aren't part of an export; enter them in each connection.")
        let names = await source.profiles.map(\.settings.name)
        XCTAssertEqual(names, ["payments-prod", "payments-prod (imported)"])
        // A Replace that only renames a folder still says what changed.
        XCTAssertEqual(ProfileTransferModel.summary(ProfileImportResult(foldersRenamed: 1)), "Renamed 1 folder.")
    }

    @MainActor func testUnreadableFilesSayWhyAndChangeNothing() async throws {
        let store = await Self.makeStore(in: directory.appendingPathComponent("a"))
        let newer = directory.appendingPathComponent("newer.json")
        try Data(#"{"format":"keel-profiles","schemaVersion":9,"folders":[],"profiles":[]}"#.utf8).write(to: newer)
        let model = ProfileTransferModel(store: store, chooseImport: { newer }, chooseExport: { nil })
        await model.beginImport()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.message, ProfileImportError.newerVersion(9).message)

        let missing = ProfileTransferModel(store: store, chooseImport: { [directory] in directory!.appendingPathComponent("missing.json") }, chooseExport: { nil })
        await missing.beginImport()
        XCTAssertEqual(missing.message, "Couldn't read the file; nothing was imported.")
        let profiles = await store.profiles
        XCTAssertTrue(profiles.isEmpty)
    }

    @MainActor func testFailedImportKeepsThePreviewOpenWithTheReason() async throws {
        let store = ProfileStore(directory: directory.appendingPathComponent("never-loaded"), secrets: MemorySecretStore())
        let file = directory.appendingPathComponent("one.json")
        try ProfileExport(profiles: [.init(id: UUID(), settings: ConnectionSettings(name: "x"))]).encoded().write(to: file)
        let model = ProfileTransferModel(store: store, chooseImport: { file }, chooseExport: { nil })
        await model.beginImport()
        XCTAssertNotNil(model.pending)
        await model.confirmImport()
        XCTAssertNotNil(model.pending, "the sheet stays so the person can cancel")
        XCTAssertNotNil(model.failure)
        model.cancelImport()
        XCTAssertNil(model.pending)

        // The same never-loaded (read-only) store refuses to export an empty document over a good file.
        let exporter = ProfileTransferModel(
            store: store, chooseImport: { nil },
            chooseExport: {
                XCTFail("no panel"); return nil
            })
        await exporter.exportConnections()
        XCTAssertEqual(exporter.message, "Connections can't be exported while they are being recovered.")
    }
}

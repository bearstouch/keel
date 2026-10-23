import Foundation
import XCTest

@testable import KeelCore

final class NamespaceTreeReviewTests: XCTestCase {
    /// A folder ID from before a separator change must not resolve to whichever folder now has that number.
    func testFolderIDFromOldTreeIsRefusedAfterSeparatorChange() async throws {
        let index = emptyIndex()
        await index.ingest(["a:1", "a:2", "b/x:1", "c/y:1"].map { Data($0.utf8) })
        let a = try await XCTUnwrapAsync(await folder(index, "a"))

        // With `/` the new tree has at least as many folders, so the old number is in range.
        await index.setSeparator(try XCTUnwrap(NamespaceSeparator(Data("/".utf8))))
        let count = await index.namespaceKeyCount(of: .root)
        XCTAssertEqual(count, 4)
        let children = await index.namespaceChildren(of: a)
        XCTAssertEqual(children, [])
        let path = await index.namespacePath(of: a)
        XCTAssertNil(path)
        let entries = await index.namespaceEntries([.folder(a)])
        XCTAssertEqual(entries, [])
        let stale = await index.namespaceKeyCount(of: a)
        XCTAssertEqual(stale, 0)

        // IDs from the rebuilt tree work, and so does the root.
        let b = try await XCTUnwrapAsync(await folder(index, "b"))
        let bPath = await index.namespacePath(of: b)
        XCTAssertEqual(bPath, Data("b".utf8))
    }

    /// The same after a restart that reloads the same keys: the old ID is refused, not silently reused.
    func testFolderIDFromBeforeRestartIsRefused() async throws {
        let index = emptyIndex()
        await index.ingest(["a:1"].map { Data($0.utf8) })
        let a = try await XCTUnwrapAsync(await folder(index, "a"))
        await index.restart()
        await index.ingest(["z:1"].map { Data($0.utf8) })
        let path = await index.namespacePath(of: a)
        XCTAssertNil(path)
    }

    /// Overlapping multi-byte separators split left to right, and keys with equal paths share one folder.
    func testOverlappingSeparatorSharesFolders() async throws {
        let separator = try XCTUnwrap(NamespaceSeparator(Data("aa".utf8)))
        let index = emptyIndex(separator: separator)
        await index.ingest(["xaaa", "xaaaab", "xaab", "x"].map { Data($0.utf8) })
        let rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["x/ (3)", "x"])
        let x = try await XCTUnwrapAsync(await folder(index, "x"))
        let xRows = await rows(index, x)
        // "xaaaab" → x / "" / b (the second `aa` starts right after the first); "xaaa" → x / "a"; "xaab" → x / "b".
        XCTAssertEqual(xRows, ["/ (1)", "a", "b"])
        let empty = try await XCTUnwrapAsync(await folder(index, "", in: x))
        let emptyRows = await rows(index, empty)
        XCTAssertEqual(emptyRows, ["b"])
        let path = await index.namespacePath(of: empty)
        XCTAssertEqual(path, Data("xaa".utf8))
    }
}

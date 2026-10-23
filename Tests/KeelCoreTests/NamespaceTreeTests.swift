import Foundation
import XCTest

@testable import KeelCore

/// A folder's rows as text: "a/ (2)" for a folder with its key count, "b" for a key's leaf name.
func rows(_ index: KeyIndex, _ folder: NamespaceFolderID = .root) async -> [String] {
    let children = await index.namespaceChildren(of: folder)
    return await index.namespaceEntries(children).map { entry in
        let name = KeyDisplay.name(entry.name)
        if case .folder = entry.child { return "\(name)/ (\(entry.keyCount))" }
        return name
    }
}

/// The folder named `name` among `parent`'s rows.
func folder(_ index: KeyIndex, _ name: String, in parent: NamespaceFolderID = .root) async -> NamespaceFolderID? {
    let children = await index.namespaceChildren(of: parent)
    for entry in await index.namespaceEntries(children) where entry.name == Data(name.utf8) {
        if case .folder(let id) = entry.child { return id }
    }
    return nil
}

func emptyIndex(separator: NamespaceSeparator = .default) -> KeyIndex {
    KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)), separator: separator)
}

final class NamespaceTreeTests: XCTestCase {
    // MARK: - Story tests

    func testKeyAndFolderCoexist() async throws {
        let index = emptyIndex()
        await index.ingest([Data("a:b".utf8), Data("a:b:c".utf8)])

        let rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a/ (2)"])
        let a = try await XCTUnwrapAsync(await folder(index, "a"))
        // `a:b` is both a folder (holding `a:b:c`) and a key; the folder is listed first.
        let aRows = await rows(index, a)
        XCTAssertEqual(aRows, ["b/ (1)", "b"])
        let ab = try await XCTUnwrapAsync(await folder(index, "b", in: a))
        let abRows = await rows(index, ab)
        XCTAssertEqual(abRows, ["c"])

        // Each row acts on the full key's bytes.
        let children = await index.namespaceChildren(of: a)
        guard case .key(let leaf) = children[1] else { return XCTFail("\(children)") }
        let key = await index.key(at: leaf)
        XCTAssertEqual(key, Data("a:b".utf8))
        let path = await index.namespacePath(of: ab)
        XCTAssertEqual(path, Data("a:b".utf8))
    }

    func testCountsUpdateIncrementally() async throws {
        let fake = ScanServer(pages: [["user:1", "user:2", "order:1"], ["user:3", "user:1:cart", "health"], ["order:2"]])
        let index = fake.index()

        await index.loadMore()
        var rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["order/ (1)", "user/ (2)"])
        var total = await index.namespaceKeyCount(of: .root)
        XCTAssertEqual(total, 3)

        await index.loadMore()
        rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["order/ (1)", "user/ (4)", "health"])
        let user = try await XCTUnwrapAsync(await folder(index, "user"))
        let userRows = await rows(index, user)
        XCTAssertEqual(userRows, ["1/ (1)", "1", "2", "3"])

        await index.loadMore()
        rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["order/ (2)", "user/ (4)", "health"])
        total = await index.namespaceKeyCount(of: .root)
        XCTAssertEqual(total, 7)
    }

    func testCustomSeparator() async throws {
        let separator = try XCTUnwrap(NamespaceSeparator(Data("::".utf8)))
        let index = emptyIndex(separator: separator)
        await index.ingest(["app::user::1", "app::user::2", "app:cfg", "app::::x", ":::y"].map { Data($0.utf8) })

        let rootRows = await rows(index)
        // `:::y` splits at the first `::`, leaving `:y`; `app:cfg` has no `::` at all.
        XCTAssertEqual(rootRows, ["/ (1)", "app/ (3)", "app:cfg"])
        let app = try await XCTUnwrapAsync(await folder(index, "app"))
        let appRows = await rows(index, app)
        XCTAssertEqual(appRows, ["/ (1)", "user/ (2)"])
        let empty = try await XCTUnwrapAsync(await folder(index, "", in: app))
        let emptyRows = await rows(index, empty)
        XCTAssertEqual(emptyRows, ["x"])
        let rootFolder = try await XCTUnwrapAsync(await folder(index, ""))
        let rootFolderRows = await rows(index, rootFolder)
        XCTAssertEqual(rootFolderRows, [":y"])
    }

    // MARK: - Extras

    func testChangingSeparatorRebuildsTree() async throws {
        let index = emptyIndex()
        await index.ingest(["a:b/c", "a:b/d", "e/f"].map { Data($0.utf8) })
        var rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a/ (2)", "e/f"])

        await index.setSeparator(try XCTUnwrap(NamespaceSeparator(Data("/".utf8))))
        rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a:b/ (2)", "e/ (1)"])
        let separator = await index.separator
        XCTAssertEqual(separator.bytes, Data("/".utf8))

        // Keys from later pages land in the rebuilt tree.
        await index.ingest([Data("e/g".utf8)])
        rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a:b/ (2)", "e/ (2)"])
    }

    func testSeparatorIsOneToFourBytes() {
        XCTAssertNil(NamespaceSeparator(Data()))
        XCTAssertNil(NamespaceSeparator(Data("12345".utf8)))
        XCTAssertEqual(NamespaceSeparator(Data("1234".utf8))?.bytes, Data("1234".utf8))
        XCTAssertEqual(NamespaceSeparator(profile: nil), .default)
        XCTAssertEqual(NamespaceSeparator(profile: "/").bytes, Data("/".utf8))
        XCTAssertEqual(NamespaceSeparator.default.bytes, Data(":".utf8))
    }

    func testRestartClearsTreeAndStaleIDsAreIgnored() async throws {
        let index = emptyIndex()
        await index.ingest(["a:1", "a:2"].map { Data($0.utf8) })
        let a = try await XCTUnwrapAsync(await folder(index, "a"))
        await index.restart()

        let rootRows = await rows(index)
        XCTAssertEqual(rootRows, [])
        let children = await index.namespaceChildren(of: a)
        XCTAssertEqual(children, [])
        let entries = await index.namespaceEntries([.folder(a), .key(0)])
        XCTAssertEqual(entries, [])
        let count = await index.namespaceKeyCount(of: a)
        XCTAssertEqual(count, 0)
    }

    func testDuplicateKeysCountOnce() async {
        let index = emptyIndex()
        await index.ingest(["a:1", "a:1", "a:2"].map { Data($0.utf8) })
        await index.ingest([Data("a:1".utf8)])
        let rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a/ (2)"])
    }

    func testChildrenSortByBytes() async throws {
        let index = emptyIndex()
        await index.ingest(["n:b", "n:a", "n:B", "n:ab", "n:", "n:\u{e9}"].map { Data($0.utf8) })
        let n = try await XCTUnwrapAsync(await folder(index, "n"))
        let nRows = await rows(index, n)
        XCTAssertEqual(nRows, ["", "B", "a", "ab", "b", "\u{e9}"])
    }

    func testManyFoldersRehash() async throws {
        let index = emptyIndex()
        await index.ingest((0..<5_000).map { Data("t:\($0):v".utf8) })
        let t = try await XCTUnwrapAsync(await folder(index, "t"))
        let children = await index.namespaceChildren(of: t)
        XCTAssertEqual(children.count, 5_000)
        let entries = await index.namespaceEntries(children)
        XCTAssertTrue(entries.allSatisfy { $0.keyCount == 1 })
        XCTAssertEqual(Set(entries.map(\.name)).count, 5_000)
    }
}

/// `XCTUnwrap` for an optional produced by an `await`.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

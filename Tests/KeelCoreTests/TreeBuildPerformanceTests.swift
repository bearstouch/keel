import Foundation
import XCTest

@testable import KeelCore

/// NFR-PF04 through the browser's own path: rebuilding the namespace tree of a `KeyIndex` holding 1,000,000 keys (a
/// separator change) takes under 2 s off the main actor, and expanding any node under 200 ms. `NamespaceTreePerformanceTests`
/// times the tree on its own; this one includes the actor hop and the arena the index keeps.
final class TreeBuildPerformanceTests: XCTestCase {
    func testOneMillionKeys() async throws {
        let index = KeyIndex(service: DataCommandService(session: RecordingServer().session()), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)))
        // The shape `ScanIngestionPerformanceTests` scans: 500k keys in one folder, 500k over 1,000 × 10 nested folders.
        var batch: [Data] = []
        batch.reserveCapacity(100_000)
        for step in 0..<1_000_000 {
            batch.append(Data(ScanIngestionPerformanceTests.key(step).utf8))
            if batch.count == 100_000 { await index.ingest(batch); batch.removeAll(keepingCapacity: true) }
        }
        let loaded = await index.count
        XCTAssertEqual(loaded, 1_000_000)

        let clock = ContinuousClock(), slash = try XCTUnwrap(NamespaceSeparator(Data("/".utf8)))
        var rebuilds: [Duration] = []
        // `/` splits nothing (one flat folder), `:` opens every folder again: both are full rebuilds of 1M keys.
        for separator in [slash, .default, slash, .default] {
            let start = clock.now
            await index.setSeparator(separator)
            rebuilds.append(clock.now - start)
        }
        let rootCount = await index.namespaceKeyCount(of: .root)
        XCTAssertEqual(rootCount, 1_000_000)

        // Expand the root, then the widest folder (500k keys) and one of the deepest, as the outline asks for rows: the
        // children, then names and counts for the first screen of them.
        var expands: [Duration] = []
        func expand(_ folder: NamespaceFolderID) async -> [NamespaceChild] {
            let start = clock.now
            let children = await index.namespaceChildren(of: folder)
            _ = await index.namespaceEntries(children.prefix(60))
            expands.append(clock.now - start)
            return children
        }
        func folder(_ name: String, in children: [NamespaceChild]) async throws -> NamespaceFolderID {
            let entries = await index.namespaceEntries(children.filter { if case .folder = $0 { true } else { false } })
            // A missing folder is a tree bug: fail rather than skip, so the budget is never silently unchecked.
            guard case .folder(let id)? = entries.first(where: { $0.name == Data(name.utf8) })?.child else { XCTFail("no folder \(name)"); throw CancellationError() }
            return id
        }
        let root = await expand(.root)
        let session = await expand(try await folder("session", in: root))
        XCTAssertEqual(session.count, 500_000)
        let user = await expand(try await folder("user", in: root))
        let deep = await expand(try await folder("07", in: await expand(try await folder("0007", in: user))))
        let cart = await expand(try await folder("cart", in: deep))
        XCTAssertEqual(cart.count, 1_000)

        let rebuild = try XCTUnwrap(rebuilds.max()), slowest = try XCTUnwrap(expands.max())
        print("KeyIndex tree 1M keys: rebuild \(rebuild) (max of \(rebuilds.count)), expand \(slowest) (max of \(expands.count))")
        BenchmarkRecorder.record("xctest.tree_rebuild_1m", rebuild)
        BenchmarkRecorder.record("xctest.tree_expand_1m", slowest)
        XCTAssertLessThan(rebuild, .seconds(2 * PerformanceBudget.slack))
        XCTAssertLessThan(slowest, .milliseconds(200 * PerformanceBudget.slack))
    }
}

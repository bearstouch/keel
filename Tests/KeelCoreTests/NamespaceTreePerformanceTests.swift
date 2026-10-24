import Foundation
import XCTest

@testable import KeelCore

/// AC4 / NFR-PF04: building the tree for 1M keys < 2 s; expanding any node < 200 ms. The budgets hold in optimized
/// builds (`swift test -c release -Xswiftc -enable-testing`); debug builds, as CI runs them, only guard against gross
/// regressions with a looser bound.
final class NamespaceTreePerformanceTests: XCTestCase {
    #if DEBUG
        static let slack = 5.0
    #else
        static let slack = 1.0
    #endif

    func testOneMillionKeysUnderBudget() throws {
        // 1M keys of ~30 bytes, laid out the way `KeyIndex` stores them: 500k under one folder (the widest node) and
        // 500k spread over 1,000 × 10 nested folders. SCAN returns keys in hash order, so they arrive scrambled
        // (a step coprime with 1M visits every number once); sorted input would flatter the sort on expand.
        var arena = ContiguousArray<UInt8>(), ends = ContiguousArray<Int>()
        for step in 0..<1_000_000 {
            let i = step * 7_919 % 1_000_000
            let key = i.isMultiple(of: 2) ? String(format: "session:%08d:token", i) : String(format: "user:%04d:%02d:cart:%08d", i % 1_000, i % 10, i)
            arena.append(contentsOf: key.utf8); ends.append(arena.count)
        }
        func withKeys<T>(_ body: (KeyBytes) -> T) -> T {
            arena.withUnsafeBytes { arena in ends.withUnsafeBufferPointer { body(KeyBytes(arena: arena, ends: $0)) } }
        }

        let clock = ContinuousClock()
        var builds: [Duration] = []
        var tree = NamespaceTree(separator: .default)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let start = clock.now
            tree = NamespaceTree(separator: .default)
            withKeys { tree.extend(with: $0) }
            builds.append(clock.now - start)
        }
        XCTAssertEqual(tree.keyCount, 1_000_000)
        XCTAssertEqual(tree.folders[0].keyCount, 1_000_000)

        // Expand every folder on the path to the widest and to the deepest node, the way the outline asks for rows.
        var expands: [Duration] = []
        func expand(_ folder: Int) -> [NamespaceChild] {
            let start = clock.now
            let children = withKeys { tree.children(of: folder, $0) }
            expands.append(clock.now - start)
            return children
        }
        func child(_ name: String, of folder: Int) throws -> Int {
            let match = expand(folder).first { child in
                guard case .folder = child else { return false }
                return withKeys { Data(tree.name(of: child, $0)) } == Data(name.utf8)
            }
            // A missing folder is a tree bug: fail rather than skip, so the budget is never silently unchecked.
            guard case .folder(let id)? = match else { XCTFail("no folder \(name)"); throw CancellationError() }
            return id.rawValue
        }
        let session = try child("session", of: 0)
        XCTAssertEqual(expand(session).count, 500_000)
        let cart = try child("cart", of: child("07", of: child("0007", of: child("user", of: 0))))
        XCTAssertEqual(expand(cart).count, 1_000)

        let build = try XCTUnwrap(builds.max()), slowest = try XCTUnwrap(expands.max())
        print("NamespaceTree 1M keys: build \(build) (max of \(builds.count)), expand \(slowest) (max of \(expands.count))")
        BenchmarkRecorder.record("xctest.namespace_tree_build_1m", build)
        BenchmarkRecorder.record("xctest.namespace_tree_expand_1m", slowest)
        XCTAssertLessThan(build, .seconds(2 * Self.slack))
        XCTAssertLessThan(slowest, .milliseconds(200 * Self.slack))
    }
}

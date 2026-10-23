import XCTest
@testable import KeelCore

/// Hands out a different PEM on each read, simulating a CA file swapped between two concurrent connects.
private final class SwappingFile: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let contents: [Data]
    init(_ contents: [Data]) { self.contents = contents }
    func read() -> Data {
        lock.withLock {
            defer { reads += 1 }; return contents[min(reads, contents.count - 1)]
        }
    }
}

final class KnownCAReviewTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS/\(name)"))
    }

    private func temporaryState() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("keel-known-ca-review-\(UUID().uuidString)", isDirectory: true) }

    /// Two connects racing the initial load must see each other's record: the second, holding a different file, is
    /// asked about instead of being trusted as another first use.
    func testConcurrentChecksDuringLoadDontTrustASwappedFile() async throws {
        let first = try fixture("keel-ca.pem"), second = try fixture("other-ca.pem")
        let profile = UUID()
        for _ in 0..<25 {
            let state = temporaryState()
            defer { try? FileManager.default.removeItem(at: state) }
            let file = SwappingFile([first, second])
            let store = KnownCAStore(directory: state) { _ throws(KnownCAError) in file.read() }
            async let a = store.check(profile: profile, caFile: "/ca.pem")
            async let b = store.check(profile: profile, caFile: "/ca.pem")
            let results = try await [a, b]
            let trusted = results.filter { if case .trusted = $0 { return true } else { return false } }.count
            XCTAssertEqual(trusted, 1, "exactly one first use; the swapped file must ask")
        }
    }

    /// Concurrent first uses of many profiles while the store loads keep every existing and new record.
    func testConcurrentFirstUsesKeepEveryRecord() async throws {
        let state = temporaryState()
        defer { try? FileManager.default.removeItem(at: state) }
        let pem = try fixture("keel-ca.pem")
        let existing = UUID()
        _ = try await KnownCAStore(directory: state) { _ throws(KnownCAError) in pem }.check(profile: existing, caFile: "/ca.pem")
        let store = KnownCAStore(directory: state) { _ throws(KnownCAError) in pem }
        let profiles = (0..<16).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for profile in profiles { group.addTask { _ = try await store.check(profile: profile, caFile: "/ca.pem") } }
            try await group.waitForAll()
        }
        let document = try PersistenceCodec.decode(KnownCADocument.self, from: Data(contentsOf: state.appendingPathComponent("known-ca.json")))
        XCTAssertEqual(Set(document.profiles.keys), Set((profiles + [existing]).map(\.uuidString)))
    }
}

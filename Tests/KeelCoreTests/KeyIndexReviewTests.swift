import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// A `RecordingTransport` whose replies wait for `release()`, so tests can act while a SCAN is in flight.
final class GatedTransport: Transport, @unchecked Sendable {
    let inner: RecordingTransport
    private let lock = NSLock()
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(answer: @escaping @Sendable ([String]) -> String) { inner = RecordingTransport(answer: answer) }

    var tlsVerified: Bool? { nil }
    func connect() async throws(TransportError) { try await inner.connect() }
    func send(_ data: Data) { inner.send(data) }
    func cancel() { release(1_000); inner.cancel() }

    func receive() async throws(TransportError) -> Data {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if permits > 0 { permits -= 1; return true }
                waiters.append(waiter); return false
            }
            if ready { waiter.resume() }
        }
        return try await inner.receive()
    }

    /// Lets `count` more replies through.
    func release(_ count: Int = 1) {
        let woken: [CheckedContinuation<Void, Never>] = lock.withLock {
            permits += count
            let take = min(permits, waiters.count)
            permits -= take
            defer { waiters.removeFirst(take) }
            return Array(waiters.prefix(take))
        }
        woken.forEach { $0.resume() }
    }
}

final class KeyIndexReviewTests: XCTestCase {
    private var transport: GatedTransport!

    private func gatedIndex(pages: [[String]], _ configuration: KeyIndexConfiguration = KeyIndexConfiguration()) -> KeyIndex {
        let gate = GatedTransport { arguments in
            guard arguments.first == "SCAN", let cursor = Int(arguments[1]), pages.indices.contains(cursor) else { return "-ERR unexpected\r\n" }
            return ScanServer.reply(cursor: cursor + 1 == pages.count ? 0 : cursor + 1, keys: pages[cursor])
        }
        transport = gate
        let session = ServerSession { (_: ConnectionRole, _: Int) async throws(ConnectionFailure) -> RedisConnection in
            let connection = RedisConnection(transport: gate)
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake connect failed", suggestion: "")
            }
            return connection
        }
        return KeyIndex(service: DataCommandService(session: session), context: DataContext(profile: SafetyProfile(name: "t", readOnly: true)), configuration: configuration)
    }

    private var scans: [[String]] { transport.inner.commands }

    private func waitForScans(_ count: Int) async {
        var spins = 0
        while scans.count < count, spins < 100_000 { await Task.yield(); spins += 1 }
        XCTAssertEqual(scans.count, count)
    }

    func testLoadMoreWhileAPageIsInFlightSendsNoSecondScan() async {
        let index = gatedIndex(pages: [keys("a", 0..<3), keys("a", 3..<6)])
        let first = Task { await index.loadMore() }
        await waitForScans(1)
        let second = await index.loadMore()
        XCTAssertEqual(second.phase, .scanning)
        transport.release()
        let status = await first.value
        XCTAssertEqual(scans.count, 1, "a double click never sends a second SCAN for the same cursor")
        XCTAssertEqual(status.loadedCount, 3)
        XCTAssertEqual(status.phase, .idle)
    }

    func testPageLandingAfterRestartIsDropped() async {
        let index = gatedIndex(pages: [keys("old", 0..<3), keys("old", 3..<6)])
        let stale = Task { await index.loadMore() }
        await waitForScans(1)
        await index.restart()
        transport.release()
        _ = await stale.value
        var status = await index.status
        XCTAssertEqual(status.loadedCount, 0, "the page of the previous scan is dropped")
        XCTAssertEqual(status.phase, .idle)

        transport.release()
        status = await index.loadMore()
        XCTAssertEqual(scans.map { $0[1] }, ["0", "0"], "the new scan starts from cursor 0")
        XCTAssertEqual(status.loadedCount, 3)
        XCTAssertEqual(status.phase, .idle)
    }

    func testLoadMoreDuringAutoPageEndsTheLoop() async {
        let index = gatedIndex(pages: (0..<5).map { keys("p", $0 * 2..<$0 * 2 + 2) })
        let auto = Task { await index.autoPage() }
        await waitForScans(1)
        await index.loadMore()
        transport.release(10)
        let status = await auto.value
        XCTAssertEqual(scans.count, 1, "switching to manual stops auto-paging after the page in flight")
        XCTAssertEqual(status.mode, .manual)
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(status.loadedCount, 2)
    }

    func testStopAutoPageLandsThePageInFlightAndKeepsTheMode() async {
        let index = gatedIndex(pages: (0..<5).map { keys("p", $0 * 2..<$0 * 2 + 2) })
        let auto = Task { await index.autoPage() }
        await waitForScans(1)
        await index.stopAutoPage()
        transport.release(10)
        var status = await auto.value
        XCTAssertEqual(scans.count, 1)
        XCTAssertEqual(status.loadedCount, 2, "the page in flight lands, unlike a cancelled task's")
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(status.mode, .auto)
        status = await index.autoPage()
        XCTAssertEqual(status.phase, .complete, "the next run continues from the cursor")
        XCTAssertEqual(status.loadedCount, 10)

        // Auto-page off while paused: back to Load more.
        await index.restart()
        await index.pause()
        await index.setPagingMode(.manual)
        status = await index.status
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(status.mode, .manual)
    }

    func testPauseDuringAutoPageStopsAfterThePageInFlight() async {
        let index = gatedIndex(pages: (0..<5).map { keys("p", $0 * 2..<$0 * 2 + 2) })
        let auto = Task { await index.autoPage() }
        await waitForScans(1)
        await index.pause()
        transport.release(10)
        let status = await auto.value
        XCTAssertEqual(scans.count, 1)
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.loadedCount, 2)
    }

    func testContinueNeverLoadsPastTheRaisedLimit() async {
        // One page of 10 against a limit of 3: Continue adds only 3 held-back keys at a time, none lost.
        let fake = ScanServer(pages: [keys("k", 0..<10), keys("k", 10..<12)])
        let index = fake.index(KeyIndexConfiguration(limit: 3))
        var status = await index.loadMore()
        XCTAssertEqual(status.loadedCount, 3)
        XCTAssertEqual(status.phase, .limitReached)

        status = await index.continueScanning()
        XCTAssertEqual(status.limit, 6)
        XCTAssertEqual(status.loadedCount, 6, "held-back keys respect the raised limit")
        XCTAssertEqual(status.phase, .limitReached)
        XCTAssertEqual(fake.scans.count, 1, "held-back keys are added before any new SCAN")

        status = await index.continueScanning()
        status = await index.continueScanning()
        XCTAssertEqual(status.loadedCount, 10)
        XCTAssertEqual(status.phase, .idle)
        status = await index.loadMore()
        XCTAssertEqual(status.phase, .complete)
        let loaded = await index.keys(in: 0..<20)
        XCTAssertEqual(loaded, keys("k", 0..<12).map { Data($0.utf8) })
    }
}

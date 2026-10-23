import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class CapabilityProbeReviewTests: XCTestCase {
    private func error(_ text: String) -> RESPValue { .error(Data(text.utf8)) }

    /// On a cluster node the random probe key usually hashes to another node: the redirect comes after the command
    /// checks, so MEMORY USAGE / OBJECT ENCODING / PEXPIRETIME are not falsely "unavailable".
    func testClusterRedirectProvesCommandLevelCapabilities() {
        for reply in [error("MOVED 3999 10.0.0.2:6379"), error("ASK 3999 10.0.0.2:6379")] {
            for capability: ServerCapability in [.memoryUsage, .objectEncoding, .pexpireTime] {
                XCTAssertEqual(CapabilityProbe.classify(reply, for: capability), .available, "\(capability)")
            }
            // A redirect says nothing about BYSCORE or exclusive ranges: take the fallback that works everywhere.
            for capability: ServerCapability in [.zrangeByScore, .xrangeExclusive] {
                XCTAssertFalse(CapabilityProbe.classify(reply, for: capability).isAvailable, "\(capability)")
            }
        }
    }

    func testKeyOnlyACLDenialProvesCommandButCommandDenialDoesNot() {
        XCTAssertEqual(CapabilityProbe.classify(error("NOPERM No permissions to access a key"), for: .memoryUsage), .available)
        XCTAssertEqual(CapabilityProbe.classify(error("NOPERM this user has no permissions to access one of the keys used as arguments"), for: .pexpireTime), .available)
        XCTAssertFalse(CapabilityProbe.classify(error("NOPERM User keyreader has no permissions to run the 'memory|usage' command"), for: .memoryUsage).isAvailable)
        XCTAssertFalse(CapabilityProbe.classify(error("NOPERM No permissions to access a key"), for: .zrangeByScore).isAvailable)
    }

    func testClusterDownIsNotCached() async throws {
        let replies = Replies(error("CLUSTERDOWN The cluster is down"))
        let session = CapabilityProbe(probeKey: Data("keel:probe:test".utf8)) { (_: [Data]) async throws(RedisError) -> RESPValue in await replies.next() }
        let down = try await session.status(.pexpireTime)
        XCTAssertFalse(down.isAvailable)
        await replies.set(.integer(-2))
        let up = try await session.status(.pexpireTime)
        XCTAssertEqual(up, .available)
    }
}

private actor Replies {
    private var reply: RESPValue
    init(_ reply: RESPValue) { self.reply = reply }
    func set(_ reply: RESPValue) { self.reply = reply }
    func next() -> RESPValue { reply }
}

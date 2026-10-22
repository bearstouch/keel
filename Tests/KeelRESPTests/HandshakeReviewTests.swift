import Foundation
import XCTest
@testable import KeelRESP

final class HandshakeReviewTests: XCTestCase {
    /// An empty password field is no password: a protected server must answer `NOAUTH` (AC2), not `WRONGPASS`.
    func testEmptyPasswordSendsNoAuth() async throws {
        let transport = FakeTransport(onSend: { transport, _ in transport.reply("%1\r\n+proto\r\n:3\r\n") })
        let connection = RedisConnection(transport: transport)
        try await connection.connect()
        _ = try await connection.handshake(HandshakeOptions(username: "", password: ""))
        XCTAssertEqual(transport.commands, [["HELLO", "3", "SETNAME", "keel"]])
    }

    /// A port whose service talks first (SSH, SMTP) breaks the stream before HELLO goes out: still `PROTOCOL_ERROR`.
    func testBannerBeforeHelloIsReportedAsCodecError() async throws {
        let transport = FakeTransport()
        let connection = RedisConnection(transport: transport)
        try await connection.connect()
        transport.reply("SSH-2.0-OpenSSH_9.8\r\n")
        let broken = await eventually {
            if case .failed = await connection.state { return true }
            return false
        }
        XCTAssertTrue(broken)
        var caught: HandshakeError?
        do throws(HandshakeError) { _ = try await connection.handshake(HandshakeOptions()) } catch { caught = error }
        guard case .connection(.codec, .hello)? = caught else { return XCTFail("unexpected \(String(describing: caught))") }
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testDumpHidesPassword() {
        var text = ""
        dump(HandshakeOptions(username: "alice", password: "s3cret"), to: &text)
        XCTAssertFalse(text.contains("s3cret"), text)
        XCTAssertTrue(text.contains("alice"), text)
    }
}

import Foundation
import XCTest

@testable import KeelRESP

final class RedisPipelineTests: XCTestCase {
    private func connected(_ transport: FakeTransport) async throws -> RedisConnection {
        let connection = RedisConnection(transport: transport, sleep: { try await ManualSleeper().sleep($0) })
        try await connection.connect()
        return connection
    }

    func testPipelineIsOneWriteAndKeepsEachReply() async throws {
        let transport = FakeTransport(onSend: { transport, frames in
            guard frames.count == 1 else { return }
            transport.reply("+OK\r\n+QUEUED\r\n*1\r\n+OK\r\n")
        })
        let connection = try await connected(transport)
        let replies = try await connection.sendPipeline([["MULTI"], ["SET", "k", "v"], ["EXEC"]].map { $0.map(bytes) })
        // One frame on the wire: nothing else sent on the connection can land between MULTI and EXEC.
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent.first, bytes("*1\r\n$5\r\nMULTI\r\n*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n*1\r\n$4\r\nEXEC\r\n"))
        XCTAssertEqual(replies.map { try? $0.get() }, [.simpleString(bytes("OK")), .simpleString(bytes("QUEUED")), .array([.simpleString(bytes("OK"))])])
    }

    func testDropMidPipelineReportsUnknownOutcomeForUnansweredWrites() async throws {
        let transport = FakeTransport(onSend: { transport, frames in
            guard frames.count == 1 else { return }
            transport.reply("+OK\r\n")
            transport.drop()
        })
        let connection = try await connected(transport)
        let replies = try await connection.sendPipeline([["MULTI"], ["SET", "k", "v"], ["EXEC"]].map { $0.map(bytes) })
        XCTAssertEqual(try replies[0].get(), .simpleString(bytes("OK")))
        XCTAssertEqual(replies.dropFirst().map { r -> RedisError? in if case .failure(let e) = r { e } else { nil } }, [.outcomeUnknown, .outcomeUnknown])
    }

    func testPipelineOnClosedConnectionSendsNothing() async throws {
        let transport = FakeTransport()
        let connection = try await connected(transport)
        await connection.close()
        do {
            _ = try await connection.sendPipeline([[bytes("PING")]])
            XCTFail("expected NOT_CONNECTED")
        } catch { XCTAssertEqual(error, .notConnected) }
        XCTAssertTrue(transport.sent.isEmpty)
    }
}

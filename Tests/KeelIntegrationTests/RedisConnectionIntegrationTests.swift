import Foundation
import KeelRESP
import XCTest

/// KEEL-005 manual check. Needs `KEEL_INTEGRATION=1` and a disposable server on 127.0.0.1 at
/// `KEEL_INTEGRATION_REDIS_PORT` (default 6379); the KEEL-048 container matrix provides one per engine.
final class RedisConnectionIntegrationTests: XCTestCase {
    func testTenThousandPipelinedPings() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1")
        let port = UInt16(environment["KEEL_INTEGRATION_REDIS_PORT"] ?? "") ?? 6_379
        let connection = RedisConnection(endpoint: .tcp(host: "127.0.0.1", port: port))
        try await connection.connect()
        let pongs = try await withThrowingTaskGroup(of: RESPValue.self) { group in
            for _ in 0..<10_000 { group.addTask { try await connection.send([Data("PING".utf8)], mayWrite: false) } }
            return try await group.reduce(into: 0) { count, reply in if reply == .simpleString(Data("PONG".utf8)) { count += 1 } }
        }
        XCTAssertEqual(pongs, 10_000)
        await connection.close()
    }
}

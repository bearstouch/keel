import Foundation
import KeelCore
import XCTest

/// Container-backed tests (KEEL-048) run only when `KEEL_INTEGRATION=1`, so a plain `swift test` never needs Docker
/// and never reaches a real server.
enum IntegrationGate {
    static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["KEEL_INTEGRATION"] == "1"
    }
}

final class IntegrationGateTests: XCTestCase {
    func testMatrixIsOptIn() {
        XCTAssertFalse(IntegrationGate.isEnabled([:]))
        XCTAssertFalse(IntegrationGate.isEnabled(["KEEL_INTEGRATION": "true"]), "Only the exact value 1 opts in")
        XCTAssertTrue(IntegrationGate.isEnabled(["KEEL_INTEGRATION": "1"]))
    }
}

/// KEEL-048 AC3 and the opt-in rules, without Docker: the matrix environment carries ports only, and malformed values
/// fail loudly rather than pointing a test somewhere unexpected.
final class IntegrationMatrixEnvironmentTests: XCTestCase {
    private let servers = #"[{"name":"redis-7.4","kind":"redis","version":"7.4.11","port":32768},{"name":"valkey-9.x","kind":"valkey","version":"9.1.2","port":32769}]"#

    func testParsesServersAndRefusedPort() throws {
        let matrix = try XCTUnwrap(try IntegrationMatrix.load(["KEEL_INTEGRATION_SERVERS": servers, "KEEL_INTEGRATION_REFUSED_PORT": "32770"]))
        XCTAssertEqual(matrix.servers.map(\.name), ["redis-7.4", "valkey-9.x"])
        XCTAssertEqual(matrix.servers.map(\.kind), [.redis, .valkey])
        XCTAssertEqual(matrix.refusedPort, 32_770)
        XCTAssertNil(try IntegrationMatrix.load([:]), "No matrix without the script's variable")
    }

    func testEveryEndpointIsLoopback() throws {
        // A host in the environment is ignored: the tests connect to the fixed loopback host only (AC3).
        let withHost = #"[{"name":"x","kind":"redis","version":"7.4.11","port":6379,"host":"redis.example.com"}]"#
        let matrix = try XCTUnwrap(try IntegrationMatrix.load(["KEEL_INTEGRATION_SERVERS": withHost]))
        XCTAssertEqual(IntegrationMatrix.host, "127.0.0.1")
        for server in matrix.servers { XCTAssertEqual(MatrixConnections.tcp(server.port), .tcp(host: "127.0.0.1", port: server.port)) }
    }

    func testMalformedValuesAreRejected() {
        for bad in [
            "not json", #"[{"name":"x","kind":"redis","version":"1","port":0}]"#, #"[{"name":"x","kind":"keydb","version":"1","port":1}]"#,
            #"[{"name":"x","kind":"redis","version":"1","port":70000}]"#, #"[{"name":"x","kind":"redis","version":"1","port":1},{"name":"x","kind":"redis","version":"1","port":2}]"#
        ] {
            XCTAssertThrowsError(try IntegrationMatrix.load(["KEEL_INTEGRATION_SERVERS": bad]), bad)
        }
        XCTAssertThrowsError(try IntegrationMatrix.load(["KEEL_INTEGRATION_SERVERS": "[]", "KEEL_INTEGRATION_REFUSED_PORT": "redis"]))
    }

    func testRequiredOnlyWithExactFlag() {
        XCTAssertTrue(IntegrationMatrix.isRequired(["KEEL_INTEGRATION_REQUIRED": "1"]))
        XCTAssertFalse(IntegrationMatrix.isRequired(["KEEL_INTEGRATION_REQUIRED": "yes"]))
        XCTAssertFalse(IntegrationMatrix.isRequired([:]))
    }

    func testManifestPinsEveryImageByDigest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Integration/matrix.json")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let servers = try XCTUnwrap(manifest["servers"] as? [[String: String]])
        // NFR-QA03's engines, each pinned (`tag@sha256:…`) so CI runs exactly what was qualified.
        XCTAssertEqual(servers.map { $0["name"] ?? "" }, ["redis-6.0", "redis-6.2", "redis-7.4", "redis-8.x", "valkey-7.2", "valkey-8.x", "valkey-9.x", "dragonfly-1.x"])
        let refused = try XCTUnwrap(manifest["refused"] as? [String: String]), tls = try XCTUnwrap(manifest["tls"] as? [String: String])
        let sshd = try XCTUnwrap(manifest["sshd"] as? [String: String])
        let images = servers.compactMap { $0["image"] } + [refused["image"], tls["image"], sshd["base"]].compactMap { $0 }
        XCTAssertEqual(images.count, servers.count + 3)
        for image in images { XCTAssertNotNil(image.range(of: #"^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$"#, options: .regularExpression), image) }
        XCTAssertTrue(refused["version"]?.hasPrefix("5.") == true, "AC2 needs a Redis 5 server")
        for server in servers { XCTAssertNotNil(ServerKind(rawValue: server["kind"] ?? ""), server["name"] ?? "") }
    }
}

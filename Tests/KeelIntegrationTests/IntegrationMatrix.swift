import Foundation
import KeelCore
import KeelRESP
import XCTest

/// One engine of the KEEL-048 matrix, as `scripts/integration-matrix.py` started it: its name in
/// `Tests/Fixtures/Integration/matrix.json`, the family and version detection must report, and its loopback port.
struct MatrixServer: Decodable, Equatable {
    var name: String
    var kind: ServerKind
    var version: String
    var port: UInt16
}

/// The containers a matrix run provides, read from the environment. The tests get ports only: every connection goes to
/// `IntegrationMatrix.host`, so no setting can send them outside the containers (AC3).
struct IntegrationMatrix: Equatable {
    static let host = "127.0.0.1"

    var servers: [MatrixServer]
    /// The Redis 5 container that must be refused with `UNSUPPORTED_SERVER`.
    var refusedPort: UInt16?

    enum Problem: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self {
            case .invalid(let text): return text
            }
        }
    }

    /// Nil without `KEEL_INTEGRATION_SERVERS` (a plain `KEEL_INTEGRATION=1` run against a hand-started server).
    static func load(_ environment: [String: String]) throws(Problem) -> IntegrationMatrix? {
        guard let json = environment["KEEL_INTEGRATION_SERVERS"] else { return nil }
        let servers: [MatrixServer]
        do { servers = try JSONDecoder().decode([MatrixServer].self, from: Data(json.utf8)) } catch {
            throw .invalid("KEEL_INTEGRATION_SERVERS isn't a list of {name, kind, version, port}: \(error)")
        }
        // Port 0 can't be a published container port; duplicate names would make a failure ambiguous.
        if servers.contains(where: { $0.port == 0 }) { throw .invalid("KEEL_INTEGRATION_SERVERS has a server on port 0") }
        if Set(servers.map(\.name)).count != servers.count { throw .invalid("KEEL_INTEGRATION_SERVERS names a server twice") }
        var refused: UInt16?
        if let text = environment["KEEL_INTEGRATION_REFUSED_PORT"] {
            guard let port = UInt16(text), port != 0 else { throw .invalid("KEEL_INTEGRATION_REFUSED_PORT isn't a port: \(text)") }
            refused = port
        }
        return IntegrationMatrix(servers: servers, refusedPort: refused)
    }

    /// `KEEL_INTEGRATION_REQUIRED=1` (set by the script, so in CI) turns a missing fixture into a failure, not a skip.
    static func isRequired(_ environment: [String: String]) -> Bool { environment["KEEL_INTEGRATION_REQUIRED"] == "1" }

    /// The matrix for a test: skipped without `KEEL_INTEGRATION=1`, or without the script's servers unless required.
    static func current(file: StaticString = #filePath, line: UInt = #line) throws -> IntegrationMatrix {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1 (scripts/integration-matrix.py does)")
        guard let matrix = try load(environment) else {
            if isRequired(environment) { throw Problem.invalid("KEEL_INTEGRATION_REQUIRED=1 but KEEL_INTEGRATION_SERVERS is missing") }
            throw XCTSkip("run scripts/integration-matrix.py to start the container matrix")
        }
        if matrix.servers.isEmpty, isRequired(environment) { throw Problem.invalid("the matrix has no servers") }
        return matrix
    }

    /// A required fixture variable; skipped when absent unless the run is required.
    static func required(_ name: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment[name], !value.isEmpty { return value }
        if isRequired(environment) { throw Problem.invalid("KEEL_INTEGRATION_REQUIRED=1 but \(name) is missing") }
        throw XCTSkip("\(name) isn't set; run scripts/integration-matrix.py")
    }

    static func port(_ name: String) throws -> UInt16 {
        let text = try required(name)
        guard let port = UInt16(text), port != 0 else { throw Problem.invalid("\(name) isn't a port: \(text)") }
        return port
    }
}

/// Connections the way the app makes them, to one matrix endpoint.
enum MatrixConnections {
    static let profile = SafetyProfile(name: "keel-matrix", readOnly: false, server: "matrix")

    /// A session whose every connection runs the app's handshake (RESP3 `HELLO`, `CLIENT SETNAME`, `SELECT`).
    static func session(_ endpoint: RedisEndpoint, username: String? = nil, password: String? = nil) -> ServerSession {
        ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let options = HandshakeOptions(username: username, password: password, database: database)
            let connection = RedisConnection(endpoint: endpoint)
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(connecting: error, endpoint: endpoint, timeout: .seconds(10)) }
            do throws(HandshakeError) { _ = try await connection.handshake(options) } catch {
                await connection.close()
                throw ConnectionFailure(handshake: error, endpoint: endpoint, options: options)
            }
            return connection
        }
    }

    static func tcp(_ port: UInt16) -> RedisEndpoint { .tcp(host: IntegrationMatrix.host, port: port) }

    /// Keys of one test run, so tests sharing a server never see each other's keys.
    static func prefix(_ test: String) -> String { "keel:matrix:\(test):\(UUID().uuidString.prefix(8)):" }
}

/// Command words as byte strings, for raw commands.
func words(_ text: String...) -> [Data] { text.map { Data($0.utf8) } }

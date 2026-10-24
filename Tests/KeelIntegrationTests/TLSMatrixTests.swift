import Foundation
import KeelCore
import KeelRESP
import Security
import XCTest

/// KEEL-048's TLS fixture (NFR-QA03): the containers `scripts/integration-matrix.py` starts from the KEEL-007
/// certificates — a server certificate from a private CA (`redis.keel.test`), and the same server requiring a client
/// certificate. Unlike `TLSIntegrationTests` (which drives `RedisConnection`), this goes through Test Connection with the
/// profile's CA file and saved client identity, then browses and edits over the encrypted connection.
@available(macOS 15, *)
final class TLSMatrixTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS")

    override func setUpWithError() throws { _ = try IntegrationMatrix.current() }

    /// The fixture client identity, decoded in memory only (never the Keychain).
    private func clientIdentity() throws -> TLSClientIdentity {
        var items: CFArray?
        let p12 = try Data(contentsOf: fixtures.appendingPathComponent("client.p12"))
        XCTAssertEqual(SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "keel-fixture", kSecImportToMemoryOnly: true] as CFDictionary, &items), errSecSuccess)
        let found = try XCTUnwrap((items as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
        return TLSClientIdentity(found as! SecIdentity)
    }

    func testCustomCAAndClientCert() async throws {
        let caPort = try IntegrationMatrix.port("KEEL_INTEGRATION_TLS_PORT"), clientAuthPort = try IntegrationMatrix.port("KEEL_INTEGRATION_TLS_CLIENT_AUTH_PORT")
        let identity = try clientIdentity(), profileID = UUID()
        // The saved identity belongs to the profile being edited; any other profile has none.
        let tester = ConnectionTester(clientIdentity: { $0 == profileID ? identity : nil })
        let tls = TLSSettings(serverName: "redis.keel.test", caFile: fixtures.appendingPathComponent("keel-ca.pem").path)
        func settings(_ port: UInt16, _ tls: TLSSettings?) -> ConnectionSettings { ConnectionSettings(name: "tls", host: IntegrationMatrix.host, port: port, tls: tls) }

        // Custom CA: untrusted without it, verified with it.
        let untrusted = await tester.test(settings(caPort, TLSSettings(serverName: "redis.keel.test")), password: nil, profileID: nil)
        XCTAssertEqual(untrusted.failure?.category, .tlsUntrusted)
        let trusted = try await tester.test(settings(caPort, tls), password: nil, profileID: nil).get()
        XCTAssertEqual(trusted.tlsVerified, true)
        XCTAssertEqual(trusted.identity.kind, .redis)

        // Client certificate: refused without the profile's identity, connected with it.
        let anonymous = await tester.test(settings(clientAuthPort, tls), password: nil, profileID: nil)
        XCTAssertEqual(anonymous.failure?.category, .tlsHandshakeFailed)
        let authenticated = try await tester.test(settings(clientAuthPort, tls), password: nil, profileID: profileID).get()
        XCTAssertEqual(authenticated.tlsVerified, true)

        // The data path over mutual TLS: create, browse and read back a key.
        let anchors = try TLSConfiguration.certificates(fromPEM: Data(contentsOf: fixtures.appendingPathComponent("keel-ca.pem")))
        let configuration = TLSConfiguration(serverName: "redis.keel.test", anchorCertificates: anchors, clientIdentity: identity)
        let session = ServerSession { (_: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let endpoint = MatrixConnections.tcp(clientAuthPort), options = HandshakeOptions(database: database)
            let connection = RedisConnection(endpoint: endpoint, tls: configuration)
            do throws(RedisError) { try await connection.connect() } catch { throw ConnectionFailure(connecting: error, endpoint: endpoint, timeout: .seconds(10), tls: configuration) }
            do throws(HandshakeError) { _ = try await connection.handshake(options) } catch { throw ConnectionFailure(handshake: error, endpoint: endpoint, options: options, tls: configuration) }
            return connection
        }
        let service = DataCommandService(session: session), context = DataContext(profile: MatrixConnections.profile)
        let prefix = MatrixConnections.prefix("tls"), key = Data("\(prefix)k".utf8)
        let created = try await NewKey.create(key, .string(Data("over-tls".utf8)), service: service, context: context)
        XCTAssertEqual(created, .created)
        let index = KeyIndex(service: service, context: context, configuration: KeyIndexConfiguration(filter: KeyFilter(pattern: prefix + "*")))
        let status = await index.autoPage()
        XCTAssertEqual(status.loadedCount, 1)
        let value = try await StringEditor.load(key: key, service: service, context: context)
        XCTAssertEqual(value.rows.map(\.value), [Data("over-tls".utf8)])
        _ = try await service.execute(.operation(.delete(keys: [key])), origin: .editor, context: context)
        await session.closeAll()
    }
}

extension Result {
    fileprivate var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}

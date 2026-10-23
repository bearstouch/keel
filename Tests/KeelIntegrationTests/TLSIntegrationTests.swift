import Foundation
import KeelCore
import KeelRESP
import Security
import XCTest

/// KEEL-007 acceptance checks against real TLS servers. Needs `KEEL_INTEGRATION=1`, the fixture servers from
/// `Tests/Fixtures/TLS/serve.sh` (ports overridable with `KEEL_INTEGRATION_TLS_PORT`, `…_TLS_CLIENT_AUTH_PORT`,
/// `…_TLS_SELF_SIGNED_PORT`) and a plain disposable server at `KEEL_INTEGRATION_REDIS_PORT` (default 6379).
/// KEEL-048's container matrix replaces the script with its TLS fixture.
@available(macOS 15, *)
final class TLSIntegrationTests: XCTestCase {
    private var ports = (privateCA: UInt16(6_380), clientAuth: UInt16(6_381), selfSigned: UInt16(6_382), plain: UInt16(6_379))
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TLS")

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1")
        func port(_ name: String, _ fallback: UInt16) -> UInt16 { UInt16(environment[name] ?? "") ?? fallback }
        ports = (
            port("KEEL_INTEGRATION_TLS_PORT", 6_380), port("KEEL_INTEGRATION_TLS_CLIENT_AUTH_PORT", 6_381), port("KEEL_INTEGRATION_TLS_SELF_SIGNED_PORT", 6_382),
            port("KEEL_INTEGRATION_REDIS_PORT", 6_379)
        )
    }

    private func customCA() throws -> [Data] { try TLSConfiguration.certificates(fromPEM: Data(contentsOf: fixtures.appendingPathComponent("keel-ca.pem"))) }

    /// The fixture client identity, decoded in memory only.
    private func clientIdentity() throws -> TLSClientIdentity {
        var items: CFArray?
        let p12 = try Data(contentsOf: fixtures.appendingPathComponent("client.p12"))
        XCTAssertEqual(SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "keel-fixture", kSecImportToMemoryOnly: true] as CFDictionary, &items), errSecSuccess)
        let found = try XCTUnwrap((items as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
        return TLSClientIdentity(found as! SecIdentity)
    }

    /// Connect, handshake and PING, as Test Connection will; failures mapped to FR-CN10 categories.
    private func open(_ port: UInt16, _ tls: TLSConfiguration?, connectTimeout: Duration = .seconds(10)) async -> Result<RedisConnection, ConnectionFailure> {
        let endpoint = RedisEndpoint.tcp(host: "127.0.0.1", port: port)
        let connection = RedisConnection(endpoint: endpoint, tls: tls, options: .init(connectTimeout: connectTimeout))
        do throws(RedisError) {
            try await connection.connect()
        } catch {
            return .failure(ConnectionFailure(connecting: error, endpoint: endpoint, timeout: connectTimeout, tls: tls))
        }
        do throws(HandshakeError) {
            _ = try await connection.handshake(HandshakeOptions())
        } catch {
            await connection.close()
            return .failure(ConnectionFailure(handshake: error, endpoint: endpoint, options: HandshakeOptions(), tls: tls))
        }
        guard (try? await connection.send([Data("PING".utf8)], mayWrite: false)) == .simpleString(Data("PONG".utf8)) else {
            await connection.close()
            return .failure(ConnectionFailure(category: .connectionFailed, message: "PING failed", suggestion: ""))
        }
        return .success(connection)
    }

    private func failure(_ result: Result<RedisConnection, ConnectionFailure>) async -> ConnectionFailure? {
        switch result {
        case .success(let connection): await connection.close(); return nil
        case .failure(let failure): return failure
        }
    }

    func testPrivateCAConnectsOnlyWhenSelected() async throws {
        let untrusted = await failure(await open(ports.privateCA, TLSConfiguration(serverName: "redis.keel.test")))
        XCTAssertEqual(untrusted?.category, .tlsUntrusted)
        XCTAssertTrue(untrusted?.message.contains("Keel Fixture CA") == true, untrusted?.message ?? "")
        let trusted = await failure(await open(ports.privateCA, TLSConfiguration(serverName: "redis.keel.test", anchorCertificates: try customCA())))
        XCTAssertNil(trusted)
    }

    func testHostnameMismatchIsFixedBySNI() async throws {
        let mismatch = await failure(await open(ports.privateCA, TLSConfiguration(anchorCertificates: try customCA())))
        XCTAssertEqual(mismatch?.category, .tlsHostnameMismatch)
        XCTAssertTrue(mismatch?.message.contains("“127.0.0.1”") == true && mismatch?.message.contains("“redis.keel.test”") == true, mismatch?.message ?? "")
        let fixed = await failure(await open(ports.privateCA, TLSConfiguration(serverName: "redis.keel.test", anchorCertificates: try customCA())))
        XCTAssertNil(fixed)
    }

    func testClientCertificateRequired() async throws {
        let without = await failure(await open(ports.clientAuth, TLSConfiguration(serverName: "redis.keel.test", anchorCertificates: try customCA())))
        XCTAssertEqual(without?.category, .tlsHandshakeFailed)
        XCTAssertTrue(without?.suggestion.contains("client certificate") == true, without?.suggestion ?? "")
        let with = await failure(await open(ports.clientAuth, TLSConfiguration(serverName: "redis.keel.test", anchorCertificates: try customCA(), clientIdentity: try clientIdentity())))
        XCTAssertNil(with)
    }

    func testSkipVerificationConnectsToSelfSigned() async throws {
        let refused = await failure(await open(ports.selfSigned, TLSConfiguration()))
        XCTAssertEqual(refused?.category, .tlsUntrusted)
        guard case .success(let connection) = await open(ports.selfSigned, TLSConfiguration(skipVerification: true)) else { return XCTFail("skip verification didn't connect") }
        XCTAssertEqual(connection.tlsVerified, false)
        await connection.close()
    }

    func testTLSToPlainServerSaysSo() async throws {
        let plain = await failure(await open(ports.plain, TLSConfiguration(), connectTimeout: .seconds(2)))
        XCTAssertEqual(plain?.category, .tlsHandshakeFailed)
        XCTAssertTrue(plain?.message.hasPrefix("Server may not be using TLS") == true, plain?.message ?? "")
        // The other way round: Redis on a TLS port closes without a word, which FR-CN10 reports with a TLS hint.
        let noTLS = await failure(await open(ports.privateCA, nil))
        XCTAssertEqual(noTLS?.category, .connectionFailed)
        XCTAssertTrue(noTLS?.suggestion.contains("TLS") == true, noTLS?.suggestion ?? "")
    }
}

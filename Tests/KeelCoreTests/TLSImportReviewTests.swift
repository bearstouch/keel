import CryptoKit
import Foundation
import KeelRESP
import Security
import XCTest
@testable import KeelCore

/// Review-driven checks for KEEL-007: hostile key files fail without trapping, and failure wording with TLS on.
final class TLSImportReviewTests: XCTestCase {
    private typealias F = TLSFixturePaths

    private func der(_ name: String) throws -> [UInt8] { Array(try XCTUnwrap(PEM.blocks(in: try F.data(name)).first).der) }

    /// Wraps DER bytes back into PEM with `label`, so mutated keys take the same path as a file the user picks.
    private func pem(_ bytes: [UInt8], _ label: String) -> Data {
        Data("-----BEGIN \(label)-----\n\(Data(bytes).base64EncodedString(options: .lineLength64Characters))\n-----END \(label)-----\n".utf8)
    }

    func testTruncatedAndCorruptedKeysFailWithoutTrapping() throws {
        let certificates = (rsa: try F.certificate("client.pem"), ec: try F.certificate("client-ec.pem"))
        let keys: [(file: String, label: String, certificate: SecCertificate)] = [
            ("client.key", "PRIVATE KEY", certificates.rsa), ("client-pkcs1.key", "RSA PRIVATE KEY", certificates.rsa),
            ("client-encrypted.key", "ENCRYPTED PRIVATE KEY", certificates.rsa), ("client-ec.key", "PRIVATE KEY", certificates.ec)
        ]
        for key in keys {
            let bytes = try der(key.file)
            XCTAssertNoThrow(try PrivateKeyDecoder.pkcs8(from: pem(bytes, key.label), passphrase: F.passphrase, certificate: key.certificate), key.file)
            for length in stride(from: 0, to: bytes.count, by: max(bytes.count / 97, 1)) {
                XCTAssertThrowsError(try PrivateKeyDecoder.pkcs8(from: pem(Array(bytes.prefix(length)), key.label), passphrase: F.passphrase, certificate: key.certificate))
            }
            // Every single-byte corruption either fails or still yields the certificate's own key; it never traps.
            for index in bytes.indices {
                var mutated = bytes
                mutated[index] ^= 0xFF
                _ = try? PrivateKeyDecoder.pkcs8(from: pem(mutated, key.label), passphrase: F.passphrase, certificate: key.certificate)
            }
        }
    }

    func testHostileDERLengthsAreMalformed() {
        let hostile: [[UInt8]] = [
            [], [0x30], [0x30, 0x80], [0x30, 0x85, 1, 0, 0, 0, 0], [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF], [0x30, 0x82, 0x01], [0x30, 0x03, 0x02, 0x01],
            [0x1F, 0x00], [0x30, 0x00, 0x00]
        ]
        for bytes in hostile { XCTAssertThrowsError(try DER.parse(bytes), "\(bytes)") }
        XCTAssertNil(DER(tag: DER.integer, content: [UInt8](repeating: 0x01, count: 9)).intValue)
        XCTAssertNil(DER(tag: DER.integer, content: [0x80]).intValue, "negative")
        XCTAssertNil(DER(tag: DER.integer, content: []).intValue)
    }

    func testExcessivePBKDF2RoundsAreRefusedBeforeDeriving() throws {
        let kdf = DER.sequence([.oid(OID.pbkdf2), .sequence([.octets([UInt8](repeating: 1, count: 16)), .integer(PBES2.maxIterations + 1)])])
        let algorithm = DER.sequence([.oid(OID.pbes2), .sequence([kdf, .sequence([.oid(OID.aes256CBC), .octets([UInt8](repeating: 2, count: 16))])])])
        let encrypted = DER.sequence([algorithm, .octets([UInt8](repeating: 3, count: 32))]).encoded
        let started = Date()
        XCTAssertThrowsError(try PBES2.decrypt(encrypted, passphrase: "x")) {
            guard case .unsupportedKey? = $0 as? TLSIdentityImportError else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testClosedStreamWithTLSOnDoesNotSuggestTurningTLSOn() {
        let endpoint = RedisEndpoint.tcp(host: "cache.internal", port: 6380)
        let closed = ConnectionFailure(handshake: .connection(.connectionLost, step: .hello), endpoint: endpoint, options: HandshakeOptions(), tls: TLSConfiguration())
        XCTAssertEqual(closed.category, .connectionFailed)
        XCTAssertFalse(closed.suggestion.contains("turn on TLS"), closed.suggestion)
        XCTAssertTrue(closed.suggestion.contains("client certificate"), closed.suggestion)
    }

    /// A SEC1 `EC PRIVATE KEY` for `scalar` on P-256, with `point` as its optional `[1] publicKey`.
    private func sec1(_ scalar: Data, point: Data? = nil) -> Data {
        let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        var fields: [DER] = [.integer(1), .octets(Array(scalar)), .explicit(0, .oid(prime256v1))]
        if let point { fields.append(.explicit(1, DER(tag: DER.bitString, content: [0] + Array(point)))) }
        return pem(DER.sequence(fields).encoded, "EC PRIVATE KEY")
    }

    /// The match check derives the public point from the scalar: neither a key file without its point (where the
    /// certificate's point used to fill in) nor one carrying the certificate's point with another scalar passes.
    func testECKeyMustMatchCertificateWhateverPointTheFileCarries() throws {
        let certificate = try F.certificate("client-ec.pem")
        let fixture = try P256.Signing.PrivateKey(pemRepresentation: String(decoding: try F.data("client-ec.key"), as: UTF8.self))
        let other = P256.Signing.PrivateKey()
        for key in [sec1(other.rawRepresentation), sec1(other.rawRepresentation, point: fixture.publicKey.x963Representation)] {
            XCTAssertThrowsError(try PrivateKeyDecoder.pkcs8(from: key, passphrase: nil, certificate: certificate)) {
                XCTAssertEqual($0 as? TLSIdentityImportError, .keyDoesNotMatchCertificate)
            }
        }
        // The matching key passes with or without its point; a wrong point next to the right scalar doesn't matter.
        for point in [nil, fixture.publicKey.x963Representation, other.publicKey.x963Representation] {
            XCTAssertNoThrow(try PrivateKeyDecoder.pkcs8(from: sec1(fixture.rawRepresentation, point: point), passphrase: nil, certificate: certificate))
        }
        // Every curve Security supports derives its point; a scalar of zero or another width has none.
        XCTAssertEqual(PrivateKeyDecoder.publicPoint(scalar: Array(other.rawRepresentation)), Array(other.publicKey.x963Representation))
        let p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
        XCTAssertEqual(PrivateKeyDecoder.publicPoint(scalar: Array(p384.rawRepresentation)), Array(p384.publicKey.x963Representation))
        XCTAssertEqual(PrivateKeyDecoder.publicPoint(scalar: Array(p521.rawRepresentation)), Array(p521.publicKey.x963Representation))
        XCTAssertNil(PrivateKeyDecoder.publicPoint(scalar: [UInt8](repeating: 0, count: 32)))
        XCTAssertNil(PrivateKeyDecoder.publicPoint(scalar: [UInt8](repeating: 1, count: 40)))
    }
}

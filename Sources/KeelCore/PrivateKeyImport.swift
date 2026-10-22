import CommonCrypto
import CryptoKit
import Foundation
import KeelRESP
import Security

/// Reads a PEM or DER private key, PKCS#8 (plain or PBES2-encrypted), PKCS#1 (`RSA PRIVATE KEY`) or SEC1
/// (`EC PRIVATE KEY`), into PKCS#8, and checks it is the key of `certificate`. Only RSA and EC keys exist in the
/// Keychain, so others are refused. Nothing here touches the Keychain: a wrong passphrase fails before any import.
enum PrivateKeyDecoder {
    static func pkcs8(from data: Data, passphrase: String?, certificate: SecCertificate) throws(TLSIdentityImportError) -> [UInt8] {
        let block = PEM.blocks(in: data).first { $0.label.hasSuffix("PRIVATE KEY") }
        let label = block?.label ?? "PRIVATE KEY"  // no PEM armour: try DER PKCS#8
        let der = Array(block?.der ?? data)
        // Pre-PKCS#8 OpenSSL encryption (MD5-based key derivation) is obsolete; asking for a conversion is safer
        // than implementing it.
        if block?.headers["Proc-Type"]?.contains("ENCRYPTED") == true {
            throw .unsupportedKey("This key uses legacy PEM encryption. Convert it with “openssl pkcs8 -topk8” and import again.")
        }
        let pkcs8: [UInt8] = try decodingKey {
            switch label {
            case "PRIVATE KEY": return der
            case "ENCRYPTED PRIVATE KEY":
                guard let passphrase, !passphrase.isEmpty else { throw TLSIdentityImportError.passphraseRequired }
                return try PBES2.decrypt(der, passphrase: passphrase)
            case "RSA PRIVATE KEY": return wrapPKCS1(der)
            case "EC PRIVATE KEY": return try wrapSEC1(der)
            default: throw TLSIdentityImportError.unreadableKey
            }
        }
        let key = try secKey(pkcs8, certificate: certificate)
        guard let certificateKey = SecCertificateCopyKey(certificate), let ours = SecKeyCopyPublicKey(key), externalBytes(ours) == externalBytes(certificateKey) else {
            throw .keyDoesNotMatchCertificate
        }
        return pkcs8
    }

    /// Runs a decoding step: import errors pass through, anything else (malformed DER) is an unreadable key.
    static func decodingKey<T>(_ body: () throws -> T) throws(TLSIdentityImportError) -> T {
        do { return try body() } catch let error as TLSIdentityImportError { throw error } catch { throw .unreadableKey }
    }

    /// A Security key from PKCS#8, to compare with the certificate's public key.
    private static func secKey(_ pkcs8: [UInt8], certificate: SecCertificate) throws(TLSIdentityImportError) -> SecKey {
        try decodingKey {
            let info = try DER.parse(pkcs8).children()
            guard info.count >= 3, info[0].intValue == 0, info[2].tag == DER.octetString, let algorithm = try info[1].children().first?.content else { throw TLSIdentityImportError.unreadableKey }
            let type: CFString, bytes: [UInt8]
            switch algorithm {
            case OID.rsaEncryption: (type, bytes) = (kSecAttrKeyTypeRSA, info[2].content)
            case OID.ecPublicKey: (type, bytes) = (kSecAttrKeyTypeECSECPrimeRandom, try x963(sec1: info[2].content, certificate: certificate))
            default: throw TLSIdentityImportError.unsupportedKey("Only RSA and EC keys can be used as client certificates.")
            }
            let attributes = [kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
            guard let key = SecKeyCreateWithData(Data(bytes) as CFData, attributes, nil) else { throw TLSIdentityImportError.unreadableKey }
            return key
        }
    }

    /// Security wants EC private keys as X9.63: `04 ‖ X ‖ Y ‖ K`. The public point comes from the SEC1 structure,
    /// or from the certificate when the key file left it out.
    private static func x963(sec1: [UInt8], certificate: SecCertificate) throws(TLSIdentityImportError) -> [UInt8] {
        try decodingKey {
            let fields = try DER.parse(sec1).children()
            guard fields.count >= 2, fields[0].intValue == 1, fields[1].tag == DER.octetString else { throw TLSIdentityImportError.unreadableKey }
            var point: [UInt8]?
            if let tagged = fields.first(where: { $0.tag == 0xA1 }), let bits = try tagged.children().first, bits.tag == DER.bitString, bits.content.count > 1 {
                point = Array(bits.content.dropFirst())  // unused-bits byte
            }
            guard let point = point ?? SecCertificateCopyKey(certificate).flatMap(externalBytes), point.first == 0x04, point.count % 2 == 1 else { throw TLSIdentityImportError.unreadableKey }
            // K is fixed-width: pad, or drop an INTEGER-style leading zero.
            let width = (point.count - 1) / 2
            var scalar = Array(fields[1].content.drop { $0 == 0 })
            guard scalar.count <= width else { throw TLSIdentityImportError.unreadableKey }
            scalar.insert(contentsOf: [UInt8](repeating: 0, count: width - scalar.count), at: 0)
            return point + scalar
        }
    }

    private static func wrapPKCS1(_ der: [UInt8]) -> [UInt8] {
        DER.sequence([.integer(0), .sequence([.oid(OID.rsaEncryption), .nullValue]), .octets(der)]).encoded
    }

    /// PKCS#8 needs the curve, which SEC1 carries in `[0] parameters`.
    private static func wrapSEC1(_ der: [UInt8]) throws(DER.Malformed) -> [UInt8] {
        let fields = try DER.parse(der).children()
        guard let curve = try fields.first(where: { $0.tag == 0xA0 })?.children().first, curve.tag == DER.oid else { throw DER.Malformed() }
        return DER.sequence([.integer(0), .sequence([.oid(OID.ecPublicKey), curve]), .octets(der)]).encoded
    }

    private static func externalBytes(_ key: SecKey) -> [UInt8]? {
        (SecKeyCopyExternalRepresentation(key, nil) as Data?).map(Array.init)
    }
}

/// PKCS#5 v2 password-based encryption (PBKDF2 + AES-CBC): OpenSSL's `-topk8 -v2` keys, and the key bag of the
/// PKCS#12 that Keel builds for a PEM pair.
enum PBES2 {
    /// At most 10 million PBKDF2 rounds, so a crafted file can't stall the importer for minutes.
    static let maxIterations = 10_000_000

    private typealias Scheme = (salt: [UInt8], iterations: Int, prf: CCPseudoRandomAlgorithm, keyLength: Int, iv: [UInt8])

    /// Decrypts `EncryptedPrivateKeyInfo` to PKCS#8. A wrong passphrase shows as bad padding or as bytes that
    /// aren't a PrivateKeyInfo.
    static func decrypt(_ der: [UInt8], passphrase: String) throws(TLSIdentityImportError) -> [UInt8] {
        let top = try PrivateKeyDecoder.decodingKey { try DER.parse(der).children() }
        guard top.count == 2, top[1].tag == DER.octetString else { throw .unreadableKey }
        let parameters = try scheme(top[0]), payload = top[1].content
        guard let key = derive(passphrase, parameters.salt, parameters.iterations, parameters.prf, parameters.keyLength),
            let plain = aes(CCOperation(kCCDecrypt), key: key, iv: parameters.iv, payload),
            let info = try? DER.parse(plain).children(), info.first?.intValue == 0
        else { throw .wrongPassphrase }
        return plain
    }

    /// `EncryptedPrivateKeyInfo` with PBKDF2-HMAC-SHA256 and AES-256-CBC, OpenSSL's defaults.
    static func encrypt(_ pkcs8: [UInt8], passphrase: String, iterations: Int = 2_048) -> DER? {
        let salt = random(16), iv = random(16)
        guard let key = derive(passphrase, salt, iterations, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32),
            let sealed = aes(CCOperation(kCCEncrypt), key: key, iv: iv, pkcs8)
        else { return nil }
        let kdf = DER.sequence([.oid(OID.pbkdf2), .sequence([.octets(salt), .integer(iterations), .sequence([.oid(OID.hmacWithSHA256), .nullValue])])])
        let algorithm = DER.sequence([.oid(OID.pbes2), .sequence([kdf, .sequence([.oid(OID.aes256CBC), .octets(iv)])])])
        return .sequence([algorithm, .octets(sealed)])
    }

    private static func scheme(_ algorithm: DER) throws(TLSIdentityImportError) -> Scheme {
        let unsupported = TLSIdentityImportError.unsupportedKey("This key's encryption isn't supported. Export it with PBKDF2 and AES, or as a .p12.")
        return try PrivateKeyDecoder.decodingKey {
            let outer = try algorithm.children()
            guard outer.count == 2, outer[0].content == OID.pbes2 else { throw unsupported }
            let parts = try outer[1].children()
            guard parts.count == 2 else { throw TLSIdentityImportError.unreadableKey }
            let kdf = try parts[0].children(), cipher = try parts[1].children()
            guard kdf.count == 2, kdf[0].content == OID.pbkdf2, cipher.count == 2, cipher[1].tag == DER.octetString, cipher[1].content.count == kCCBlockSizeAES128 else { throw unsupported }
            let keyLength: Int
            switch cipher[0].content {
            case OID.aes128CBC: keyLength = 16
            case OID.aes192CBC: keyLength = 24
            case OID.aes256CBC: keyLength = 32
            default: throw unsupported
            }
            let fields = try kdf[1].children()
            guard fields.count >= 2, fields[0].tag == DER.octetString, let iterations = fields[1].intValue, (1...maxIterations).contains(iterations) else { throw unsupported }
            // Optional keyLength INTEGER, then optional prf AlgorithmIdentifier (default HMAC-SHA1).
            var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            if let identifier = fields.dropFirst(2).first(where: { $0.tag == DER.sequence }) {
                switch try identifier.children().first?.content {
                case OID.hmacWithSHA1?: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
                case OID.hmacWithSHA256?: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
                case OID.hmacWithSHA384?: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
                case OID.hmacWithSHA512?: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
                default: throw unsupported
                }
            }
            return (fields[0].content, iterations, prf, keyLength, cipher[1].content)
        }
    }

    private static func derive(_ passphrase: String, _ salt: [UInt8], _ iterations: Int, _ prf: CCPseudoRandomAlgorithm, _ length: Int) -> [UInt8]? {
        var key = [UInt8](repeating: 0, count: length)
        let password = Array(passphrase.utf8)
        let status = password.withUnsafeBufferPointer { pass in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pass.count, salt, salt.count, prf, UInt32(iterations), &key,
                length)
        }
        return status == kCCSuccess ? key : nil
    }

    private static func aes(_ operation: CCOperation, key: [UInt8], iv: [UInt8], _ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input, input.count, &output, output.count, &moved)
        return status == kCCSuccess ? Array(output.prefix(moved)) : nil
    }

    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

/// Wraps a certificate and its PKCS#8 key into a PKCS#12 so a PEM pair takes the same, only, Keychain import path
/// as a `.p12`: on macOS `SecPKCS12Import` is the one non-deprecated API that stores a private key in the login
/// keychain. The key bag must be shrouded (encrypted); the Keychain ignores plain key bags.
enum PKCS12Builder {
    static func build(certificate: [UInt8], pkcs8: [UInt8], passphrase: String) -> Data? {
        guard let shrouded = PBES2.encrypt(pkcs8, passphrase: passphrase) else { return nil }
        // localKeyID pairs the certificate with its key.
        let attributes = DER.set([.sequence([.oid(OID.localKeyID), .set([.octets([0x4B, 0x45, 0x45, 0x4C])])])])
        let certBag = DER.sequence([.oid(OID.certBag), .explicit(0, .sequence([.oid(OID.x509Certificate), .explicit(0, .octets(certificate))])), attributes])
        let keyBag = DER.sequence([.oid(OID.shroudedKeyBag), .explicit(0, shrouded), attributes])
        let safes = [certBag, keyBag].map { bag in DER.sequence([.oid(OID.data), .explicit(0, .octets(DER.sequence([bag]).encoded))]) }
        let authenticatedSafe = DER.sequence(safes).encoded
        let salt = PBES2.random(16), iterations = 2_048
        let macKey = SymmetricKey(data: kdf(passphrase, salt: salt, id: 3, iterations: iterations, length: 32))
        let mac = Array(HMAC<SHA256>.authenticationCode(for: authenticatedSafe, using: macKey))
        let macData = DER.sequence([.sequence([.sequence([.oid(OID.sha256), .nullValue]), .octets(mac)]), .octets(salt), .integer(iterations)])
        let pfx = DER.sequence([.integer(3), .sequence([.oid(OID.data), .explicit(0, .octets(authenticatedSafe))]), macData])
        return Data(pfx.encoded)
    }

    /// The PKCS#12 key derivation (RFC 7292 appendix B.2) with SHA-256: u = 32, v = 64. `id` 3 derives MAC keys.
    static func kdf(_ passphrase: String, salt: [UInt8], id: UInt8, iterations: Int, length: Int) -> [UInt8] {
        let u = 32, v = 64
        // BMPString: UTF-16 big-endian with a two-byte terminator.
        let password: [UInt8] = passphrase.utf16.flatMap { unit -> [UInt8] in [UInt8(unit >> 8), UInt8(unit & 0xFF)] } + [0, 0]
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            bytes.isEmpty ? [] : (0..<(v * ((bytes.count + v - 1) / v))).map { bytes[$0 % bytes.count] }
        }
        let diversifier = [UInt8](repeating: id, count: v)
        var input = stretch(salt) + stretch(password)
        var output: [UInt8] = []
        while output.count < length {
            var block = Array(SHA256.hash(data: diversifier + input))
            for _ in 1..<max(iterations, 1) { block = Array(SHA256.hash(data: block)) }
            output += block
            // I_j = (I_j + B + 1) mod 2^(v·8), with B = block repeated to v bytes.
            let b = (0..<v).map { block[$0 % u] }
            for start in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for k in (0..<v).reversed() {
                    let sum = Int(input[start + k]) + Int(b[k]) + carry
                    input[start + k] = UInt8(sum & 0xFF); carry = sum >> 8
                }
            }
        }
        return Array(output.prefix(length))
    }
}

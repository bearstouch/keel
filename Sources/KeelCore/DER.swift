import Foundation

/// The little ASN.1 DER that key import needs: reading PKCS#8 / PKCS#1 / SEC1 keys and writing PKCS#12.
/// Definite lengths only (DER has no others); every read is bounds-checked, so a hostile file fails, never traps.
struct DER: Equatable {
    var tag: UInt8
    var content: [UInt8]

    static let integer: UInt8 = 0x02, bitString: UInt8 = 0x03, octetString: UInt8 = 0x04, null: UInt8 = 0x05, oid: UInt8 = 0x06
    static let sequence: UInt8 = 0x30, set: UInt8 = 0x31

    struct Malformed: Error {}

    // MARK: - Reading

    /// The single element that makes up `bytes`; trailing bytes are malformed.
    static func parse(_ bytes: [UInt8]) throws(Malformed) -> DER {
        var index = 0
        let element = try read(bytes, &index)
        guard index == bytes.count else { throw Malformed() }
        return element
    }

    /// The elements inside a constructed element (SEQUENCE, SET, context tag).
    func children() throws(Malformed) -> [DER] {
        var index = 0, elements: [DER] = []
        while index < content.count { elements.append(try Self.read(content, &index)) }
        return elements
    }

    private static func read(_ bytes: [UInt8], _ index: inout Int) throws(Malformed) -> DER {
        guard index + 2 <= bytes.count else { throw Malformed() }
        let tag = bytes[index]
        // Multi-byte tags (low bits 0x1F) never occur in the structures read here.
        guard tag & 0x1F != 0x1F else { throw Malformed() }
        var length = Int(bytes[index + 1])
        index += 2
        if length & 0x80 != 0 {
            let octets = length & 0x7F
            guard (1...4).contains(octets), index + octets <= bytes.count else { throw Malformed() }
            length = bytes[index..<index + octets].reduce(0) { $0 << 8 | Int($1) }
            index += octets
        }
        guard length <= bytes.count - index else { throw Malformed() }
        defer { index += length }
        return DER(tag: tag, content: Array(bytes[index..<index + length]))
    }

    /// A non-negative INTEGER that fits an Int (iteration counts, key lengths, versions).
    var intValue: Int? {
        guard tag == Self.integer, (1...8).contains(content.count), content[0] & 0x80 == 0 else { return nil }
        return content.reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: - Writing

    var encoded: [UInt8] {
        var bytes = [tag]
        if content.count < 0x80 {
            bytes.append(UInt8(content.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(content.count).bigEndian, Array.init).drop { $0 == 0 }
            bytes.append(0x80 | UInt8(length.count)); bytes += length
        }
        return bytes + content
    }

    static func sequence(_ elements: [DER]) -> DER { DER(tag: sequence, content: elements.flatMap(\.encoded)) }
    static func set(_ elements: [DER]) -> DER { DER(tag: set, content: elements.flatMap(\.encoded)) }
    static func octets(_ bytes: [UInt8]) -> DER { DER(tag: octetString, content: bytes) }
    static func oid(_ bytes: [UInt8]) -> DER { DER(tag: oid, content: bytes) }
    static let nullValue = DER(tag: null, content: [])
    /// `[n] EXPLICIT`, constructed context-specific.
    static func explicit(_ number: UInt8, _ element: DER) -> DER { DER(tag: 0xA0 | number, content: element.encoded) }

    static func integer(_ value: Int) -> DER {
        var bytes = Array(withUnsafeBytes(of: UInt64(value).bigEndian, Array.init).drop { $0 == 0 })
        if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return DER(tag: integer, content: bytes)
    }
}

/// Object identifiers used by key import, as DER content bytes.
enum OID {
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    static let pbes2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]
    static let pbkdf2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]
    static let hmacWithSHA1: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07]
    static let hmacWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09]
    static let hmacWithSHA384: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0A]
    static let hmacWithSHA512: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0B]
    static let aes128CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02]
    static let aes192CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16]
    static let aes256CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A]
    static let sha256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
    // PKCS#7 / PKCS#12 / PKCS#9
    static let data: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
    static let shroudedKeyBag: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02]
    static let certBag: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03]
    static let x509Certificate: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01]
    static let localKeyID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15]
}

import Foundation

/// How key names (and tree segments) are shown and copied (FR-KB10). Display text is never turned back into a
/// command: every action uses the key's original bytes from `KeyIndex`.
public enum KeyDisplay {
    /// Valid UTF-8 shows as is. Anything else — invalid UTF-8, control characters, or bidi controls that would
    /// reorder the row — gets redis-cli escaping (`\xff\x00a`), so odd bytes are visible and can't spoof a name.
    public static func name(_ bytes: Data) -> String {
        // Decoding repairs invalid UTF-8 with U+FFFD, so the round trip only matches for valid input.
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) && !text.unicodeScalars.contains(where: needsEscape) ? text : escaped(bytes)
    }

    /// "Copy as redis-cli argument": the double-quoted form redis-cli and Keel's console parse back to the same bytes.
    public static func redisCliArgument(_ bytes: Data) -> String { "\"" + escaped(bytes) + "\"" }

    /// redis-cli's `sdscatrepr` without the quotes: `\\ \" \n \r \t \a \b`, printable ASCII as is, every other byte `\xNN`.
    public static func escaped(_ bytes: Data) -> String {
        var out = ""
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            switch byte {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(byte))
            default: out += "\\x" + String(byte >> 4, radix: 16) + String(byte & 0xF, radix: 16)
            }
        }
        return out
    }

    /// C0/C1 controls and DEL, plus the bidi embedding, override and isolate controls.
    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
}

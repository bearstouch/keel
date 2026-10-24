import Foundation

/// Credentials typed in the console never show (FR-CO10): `AUTH`, `HELLO … AUTH`, `ACL SETUSER … >password`,
/// `CONFIG SET requirepass` / `masterauth` and `MIGRATE … AUTH` print as `••••••` in the echo, and the history keeps
/// only that masked line. The bytes sent are the typed ones; masking is display only.
public enum ConsoleMasking {
    /// Always six dots, so the echo doesn't tell the secret's length.
    public static let mask = "••••••"

    /// The arguments to hide in `arguments` (0-based, the command name is 0). Commands are matched case-insensitively.
    public static func maskedIndexes(_ arguments: [Data]) -> Set<Int> {
        let words = arguments.map { String(decoding: $0, as: UTF8.self).lowercased() }
        guard let name = words.first else { return [] }
        switch name {
        case "auth":
            // `AUTH password` or `AUTH username password`: the password is the last argument.
            return words.count > 1 ? [words.count - 1] : []
        case "hello":
            // `HELLO protover AUTH username password [SETNAME name]`.
            guard let auth = words.indices.dropFirst(2).first(where: { words[$0] == "auth" }), auth + 2 < words.count else { return [] }
            return [auth + 2]
        case "acl" where words.count > 3 && words[1] == "setuser":
            // Rules after the user name: `>pass` / `<pass` add or remove a password, `#hash` / `!hash` a hashed one.
            return Set(words.indices.dropFirst(3).filter { index in arguments[index].first.map { Self.passwordRules.contains($0) } ?? false })
        case "config" where words.count > 3 && words[1] == "set":
            // `CONFIG SET parameter value [parameter value …]`.
            return Set(stride(from: 2, to: words.count - 1, by: 2).filter { Self.secretParameters.contains(words[$0]) }.map { $0 + 1 })
        case "migrate":
            // `MIGRATE host port key db timeout [COPY] [REPLACE] [AUTH password | AUTH2 username password] [KEYS key …]`:
            // options start after the timeout and end at KEYS, whose key names may look like tokens.
            var masked: Set<Int> = []
            var index = 6
            while index < words.count, words[index] != "keys" {
                if words[index] == "auth", index + 1 < words.count { masked.insert(index + 1); index += 2; continue }
                if words[index] == "auth2", index + 2 < words.count { masked.insert(index + 2); index += 3; continue }
                index += 1
            }
            return masked
        default:
            return []
        }
    }

    /// The line to echo and keep in history: `line` as typed, or rebuilt with the masked arguments replaced when there
    /// are any (the typed spelling of a secret can't be kept, so the other arguments are re-quoted like redis-cli).
    public static func display(_ line: String, arguments: [Data]) -> String {
        let masked = maskedIndexes(arguments)
        guard !masked.isEmpty else { return line }
        let isACL = String(decoding: arguments[0], as: UTF8.self).lowercased() == "acl"
        return arguments.indices.map { index in
            if masked.contains(index) {
                // An ACL rule keeps its `>` / `#` so the echo still says what the rule did.
                if isACL, let rule = arguments[index].first { return String(UnicodeScalar(rule)) + mask }
                return mask
            }
            return plain(arguments[index]) ?? KeyDisplay.redisCliArgument(arguments[index])
        }
        .joined(separator: " ")
    }

    /// A line that couldn't be split into arguments (FR-CO02) is echoed too: when it starts with a command that takes
    /// credentials, only that name is kept, since where its secret starts can't be told.
    public static func displayUnparsed(_ line: String) -> String {
        let name = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return credentialCommands.contains(name.lowercased()) ? name + " " + mask : line
    }

    private static let credentialCommands: Set<String> = ["auth", "hello", "acl", "config", "migrate"]
    private static let passwordRules: Set<UInt8> = [UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "#"), UInt8(ascii: "!")]
    /// Valkey also spells `masterauth` as `primaryauth`; the TLS key passphrases are secrets too.
    private static let secretParameters: Set<String> = ["requirepass", "masterauth", "primaryauth", "tls-key-file-pass", "tls-client-key-file-pass"]

    /// An argument that reads back the same without quotes: printable ASCII without spaces, quotes or backslashes.
    private static func plain(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "'") && $0 != UInt8(ascii: "\\") }) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

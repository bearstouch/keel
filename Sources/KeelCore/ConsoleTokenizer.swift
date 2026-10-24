import Foundation

/// Why a console line couldn't be split into arguments (FR-CO02). Nothing is sent for such a line.
public enum ConsoleParseError: Error, Equatable, Sendable {
    /// A double- or single-quoted argument has no closing quote.
    case unbalancedQuotes
    /// A closing quote is followed by something other than whitespace (`"a"b`).
    case textAfterClosingQuote

    public var code: String { "INVALID_PARAMS" }

    /// The inline console error; redis-cli says only "Invalid argument(s)".
    public var message: String {
        switch self {
        case .unbalancedQuotes: return "Invalid argument(s): unbalanced quotes"
        case .textAfterClosingQuote: return "Invalid argument(s): a closing quote must be followed by a space"
        }
    }
}

/// Splits a console line into argument bytes exactly like redis-cli (`sdssplitargs`, FR-CO02): arguments are separated
/// by whitespace; double quotes take `\n \r \t \b \a \\ \" \xNN` (any other escaped character stands for itself); single
/// quotes are literal except `\'`. A quote may start mid-argument (`a"b c"` is `ab c`), but a closing quote must end it.
public enum ConsoleTokenizer {
    /// The arguments of `line` as bytes (empty for a blank line). Text outside escapes is sent as its UTF-8 bytes.
    public static func arguments(_ line: String) throws(ConsoleParseError) -> [Data] {
        var bytes = Array(line.utf8)
        // redis-cli reads a C string, so a NUL ends the line; everything after it is dropped the same way here.
        if let nul = bytes.firstIndex(of: 0) { bytes.removeSubrange(nul...) }
        let count = bytes.count
        func at(_ index: Int) -> UInt8 { index < count ? bytes[index] : 0 }

        var arguments: [Data] = []
        var index = 0
        while true {
            while index < count, isSpace(bytes[index]) { index += 1 }
            guard index < count else { return arguments }
            var current: [UInt8] = []
            var inDouble = false, inSingle = false, done = false
            while !done {
                let byte = at(index)
                if inDouble {
                    if byte == backslash, at(index + 1) == UInt8(ascii: "x"), let high = hexValue(at(index + 2)), let low = hexValue(at(index + 3)) {
                        current.append(high << 4 | low); index += 3
                    } else if byte == backslash, at(index + 1) != 0 {
                        index += 1; current.append(unescaped(bytes[index]))
                    } else if byte == doubleQuote {
                        guard at(index + 1) == 0 || isSpace(at(index + 1)) else { throw .textAfterClosingQuote }
                        done = true
                    } else if byte == 0 {
                        throw .unbalancedQuotes
                    } else {
                        current.append(byte)
                    }
                } else if inSingle {
                    if byte == backslash, at(index + 1) == singleQuote {
                        index += 1; current.append(singleQuote)
                    } else if byte == singleQuote {
                        guard at(index + 1) == 0 || isSpace(at(index + 1)) else { throw .textAfterClosingQuote }
                        done = true
                    } else if byte == 0 {
                        throw .unbalancedQuotes
                    } else {
                        current.append(byte)
                    }
                } else {
                    // Only these end an unquoted argument; `\v` and `\f` are kept, as in redis-cli.
                    switch byte {
                    case 0x20, 0x0A, 0x0D, 0x09, 0: done = true
                    case doubleQuote: inDouble = true
                    case singleQuote: inSingle = true
                    default: current.append(byte)
                    }
                }
                // Step past the byte just handled (closing quote or separator included), but never past the end.
                if index < count { index += 1 }
            }
            arguments.append(Data(current))
        }
    }

    private static let backslash = UInt8(ascii: "\\"), doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'")

    /// C `isspace`: space, `\t \n \v \f \r`.
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func unescaped(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "n"): return 0x0A
        case UInt8(ascii: "r"): return 0x0D
        case UInt8(ascii: "t"): return 0x09
        case UInt8(ascii: "b"): return 0x08
        case UInt8(ascii: "a"): return 0x07
        default: return byte
        }
    }
}

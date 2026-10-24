import Foundation
import KeelRESP

/// Prints a reply the way interactive redis-cli 7 does (`cliFormatReplyTTY`, FR-CO03): `(integer) 5`, bulk strings
/// quoted with `sdscatrepr` escaping, status and error text as is, `(nil)`, `(empty array)` and numbered, indented
/// aggregates (`1)` arrays and pushes, `1~` sets, `1# k => v` maps). Display only: commands never use this text.
public enum RedisCliFormatter {
    /// The console text for `reply`, ending in a newline.
    public static func format(_ reply: RESPValue) -> String {
        var out = ""
        write(reply, prefix: "", indentFirst: false, into: &out)
        return out
    }

    /// `prefix` indents every line of an aggregate but the first, which follows its parent's index on the same line —
    /// unless `indentFirst`: redis-cli starts a map value on a line of its own when it spans lines (`isMultiLine`).
    private static func write(_ value: RESPValue, prefix: String, indentFirst: Bool, into out: inout String) {
        switch value {
        case .error(let text), .blobError(let text): out += "(error) " + text.lossyText + "\n"
        case .simpleString(let text): out += text.lossyText + "\n"
        case .integer(let number): out += "(integer) \(number)\n"
        case .double(let number): out += "(double) " + serverText(number) + "\n"
        // redis-cli 7.2 exits on a big number ("Unknown reply type"); Keel labels it like the other RESP3 scalars.
        case .bigNumber(let digits): out += "(big number) " + digits + "\n"
        case .bulkString(let bytes): out += KeyDisplay.redisCliArgument(bytes) + "\n"
        case .verbatim(_, let text): out += text.lossyText + "\n"
        case .null, .nullBulkString, .nullArray: out += "(nil)\n"
        case .boolean(let flag): out += flag ? "(true)\n" : "(false)\n"
        // redis-cli can't read attributes; Keel shows the reply they annotate, as a RESP2 connection would get it.
        case .attribute(_, let reply): write(reply, prefix: prefix, indentFirst: indentFirst, into: &out)
        case .array(let elements): writeList(elements, empty: "(empty array)", separator: ")", prefix: prefix, indentFirst: indentFirst, into: &out)
        case .push(let elements): writeList(elements, empty: "(empty push)", separator: ")", prefix: prefix, indentFirst: indentFirst, into: &out)
        case .set(let elements): writeList(elements, empty: "(empty set)", separator: "~", prefix: prefix, indentFirst: indentFirst, into: &out)
        case .map(let pairs):
            guard !pairs.isEmpty else { out += "(empty hash)\n"; return }
            let width = String(pairs.count).count, childPrefix = prefix + String(repeating: " ", count: width + 2)
            for (index, pair) in pairs.enumerated() {
                out += (index == 0 && !indentFirst ? "" : prefix) + number(index + 1, width: width) + "# "
                write(pair.key, prefix: childPrefix, indentFirst: false, into: &out)
                // The key's newline gives way to ` => `; unicode scalars, since a trailing "\r\n" is one Character.
                out.unicodeScalars.removeLast()
                let nested = pair.value.isMultiLine
                out += nested ? " => \n" : " => "
                write(pair.value, prefix: childPrefix, indentFirst: nested, into: &out)
            }
        }
    }

    /// Arrays, sets and pushes: indexes right-aligned to the widest one, nested lines indented past it.
    private static func writeList(_ elements: [RESPValue], empty: String, separator: String, prefix: String, indentFirst: Bool, into out: inout String) {
        guard !elements.isEmpty else { out += empty + "\n"; return }
        let width = String(elements.count).count, childPrefix = prefix + String(repeating: " ", count: width + 2)
        for (index, element) in elements.enumerated() {
            out += (index == 0 && !indentFirst ? "" : prefix) + number(index + 1, width: width) + separator + " "
            write(element, prefix: childPrefix, indentFirst: false, into: &out)
        }
    }

    private static func number(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: " ", count: width - digits.count) + digits
    }

    /// The text Redis 7 sends for a RESP3 double (`d2string` + `fpconv_dtoa`), which redis-cli prints verbatim: the
    /// shortest round-trip digits, as a plain number while the decimal exponent stays within bounds, otherwise
    /// `1.5e-7` / `1e+20` with an unpadded exponent. RESPValue keeps only the `Double`, so the layout is rebuilt here.
    static func serverText(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        let sign = value < 0 ? "-" : ""
        // Shortest digits and decimal exponent from Swift's round-trip description: value = 0.digits… as digits × 10^k.
        let text = abs(value).description
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0], exponent = parts.count > 1 ? Int(parts[1])! : 0
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = pieces.count > 1 ? pieces[1] : ""
        var digits = Array((pieces[0] + fraction).drop(while: { $0 == "0" }))
        var k = exponent - fraction.count
        while digits.last == "0" { digits.removeLast(); k += 1 }
        let count = digits.count, decimalExponent = k + count - 1, magnitude = abs(decimalExponent)

        if k >= 0 && magnitude <= 18 { return sign + String(digits) + String(repeating: "0", count: k) }
        if k < 0 && (k > -7 || magnitude < 4) {
            let point = count + k
            if point > 0 { return sign + String(digits[..<point]) + "." + String(digits[point...]) }
            return sign + "0." + String(repeating: "0", count: -point) + String(digits)
        }
        let rest = count > 1 ? "." + String(digits[1...]) : ""
        return sign + String(digits[0]) + rest + "e" + (decimalExponent < 0 ? "-" : "+") + String(magnitude)
    }
}

extension RESPValue {
    /// redis-cli 7.2's test for a map value that goes on its own line, probed against the binary: an aggregate with more
    /// than one element (pairs, for a map), or one whose single element (map: value; keys don't count) is such a value.
    /// `=> 1) (integer) 1` and `=> 1# k => (integer) 1` stay inline; a verbatim string's own newlines don't count.
    fileprivate var isMultiLine: Bool {
        switch self {
        case .array(let elements), .set(let elements), .push(let elements): return elements.count > 1 || elements.contains { $0.isMultiLine }
        case .map(let pairs): return pairs.count > 1 || pairs.contains { $0.value.isMultiLine }
        case .attribute(_, let reply): return reply.isMultiLine
        default: return false
        }
    }
}

extension Data {
    /// Status, error and verbatim text is printed raw by redis-cli; invalid UTF-8 becomes U+FFFD here.
    fileprivate var lossyText: String { String(decoding: self, as: UTF8.self) }
}

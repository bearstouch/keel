import Foundation

/// RESP encoding. Commands always go out as an array of bulk strings, so any byte (CRLF and NUL included) is safe
/// in a key, value or argument.
public enum RESPEncoder {
    /// `*<n>\r\n` then `$<len>\r\n<bytes>\r\n` per argument; `["SET", "k", "v"]` → `*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n`.
    public static func command(_ arguments: [Data]) -> Data {
        var out = Data(capacity: arguments.reduce(16) { $0 + $1.count + 16 })
        out.appendHeader(Byte.star, arguments.count)
        for argument in arguments { out.appendBlob(Byte.dollar, argument) }
        return out
    }

    /// Any reply in its wire form; used by fake servers and round-trip tests. Fails for values that can't be
    /// framed: CR/LF inside a simple string or error, a malformed big number or verbatim format, or nesting deeper
    /// than `maxDepth`.
    public static func encode(_ value: RESPValue, maxDepth: Int = RESPLimits.standard.maxDepth) throws(RESPError) -> Data {
        var out = Data()
        try encode(value, into: &out, depth: 0, maxDepth: maxDepth)
        return out
    }

    private static func encode(_ value: RESPValue, into out: inout Data, depth: Int, maxDepth: Int) throws(RESPError) {
        func children(_ type: UInt8, _ items: [RESPValue]) throws(RESPError) {
            guard depth < maxDepth else { throw .protocolError(.nestingTooDeep) }
            out.appendHeader(type, items.count)
            for item in items { try encode(item, into: &out, depth: depth + 1, maxDepth: maxDepth) }
        }
        func pairs(_ type: UInt8, _ entries: [RESPPair]) throws(RESPError) {
            guard depth < maxDepth else { throw .protocolError(.nestingTooDeep) }
            out.appendHeader(type, entries.count)
            for entry in entries {
                try encode(entry.key, into: &out, depth: depth + 1, maxDepth: maxDepth)
                try encode(entry.value, into: &out, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        func line(_ type: UInt8, _ bytes: Data) throws(RESPError) {
            guard !bytes.contains(Byte.cr), !bytes.contains(Byte.lf) else { throw .protocolError(.unframeable) }
            out.appendLine(type, bytes)
        }
        switch value {
        case .simpleString(let bytes): try line(Byte.plus, bytes)
        case .error(let bytes): try line(Byte.minus, bytes)
        case .integer(let number): out.appendLine(Byte.colon, Data(String(number).utf8))
        case .bulkString(let bytes): out.appendBlob(Byte.dollar, bytes)
        case .blobError(let bytes): out.appendBlob(Byte.bang, bytes)
        case .nullBulkString: out.append(contentsOf: "$-1\r\n".utf8)
        case .nullArray: out.append(contentsOf: "*-1\r\n".utf8)
        case .null: out.append(contentsOf: "_\r\n".utf8)
        case .double(let number): out.appendLine(Byte.comma, Data(text(number).utf8))
        case .boolean(let flag): out.append(contentsOf: (flag ? "#t\r\n" : "#f\r\n").utf8)
        case .bigNumber(let digits):
            guard RESPParser.isBigNumber(Array(digits.utf8)[...]) else { throw .protocolError(.invalidBigNumber) }
            out.appendLine(Byte.paren, Data(digits.utf8))
        case .verbatim(let format, let bytes):
            let formatBytes = Array(format.utf8)
            guard RESPParser.isVerbatimFormat(formatBytes) else { throw .protocolError(.invalidVerbatim) }
            out.appendBlob(Byte.equals, Data(formatBytes + [Byte.colon]) + bytes)
        case .array(let items): try children(Byte.star, items)
        case .set(let items): try children(Byte.tilde, items)
        case .push(let items): try children(Byte.greater, items)
        case .map(let entries): try pairs(Byte.percent, entries)
        case .attribute(let entries, let annotated):
            // The annotated value counts one level deeper, matching the parser, so a long attribute chain is bounded too.
            try pairs(Byte.pipe, entries)
            try encode(annotated, into: &out, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// The parser's double grammar: `inf`, `-inf`, `nan`, else Swift's shortest round-trip form (`1.5`, `1e+100`).
    private static func text(_ number: Double) -> String {
        if number.isNaN { return "nan" }
        if number.isInfinite { return number < 0 ? "-inf" : "inf" }
        return "\(number)"
    }
}

extension Data {
    fileprivate mutating func appendHeader(_ type: UInt8, _ count: Int) { appendLine(type, Data(String(count).utf8)) }

    fileprivate mutating func appendLine(_ type: UInt8, _ content: Data) {
        append(type); append(content); append(contentsOf: [Byte.cr, Byte.lf])
    }

    fileprivate mutating func appendBlob(_ type: UInt8, _ payload: Data) {
        appendHeader(type, payload.count); append(payload); append(contentsOf: [Byte.cr, Byte.lf])
    }
}

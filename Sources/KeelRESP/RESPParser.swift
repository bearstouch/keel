import Foundation

/// Incremental RESP2/RESP3 reply parser (INT-03, NFR-RL05, NFR-RS03).
///
/// Feed bytes as they arrive with `append(_:)`, then call `next()` until it returns nil; pipelined replies come
/// out in order. Parsing resumes where the last chunk ended, so no byte is scanned twice and a reply split at any
/// offset decodes to the same value. Aggregates are tracked on an explicit stack rather than by recursion, and a
/// declared length or count never allocates anything: only bytes that actually arrived are buffered.
///
/// The first error is final: every later `next()` throws it again and the connection must be closed.
public struct RESPParser: Sendable {
    public let limits: RESPLimits

    private var buffer: [UInt8] = []
    /// Next unread byte in `buffer`.
    private var position = 0
    /// Where the CR/LF search for the line at `position` resumes, so a long line arriving in pieces is scanned once.
    private var lineScanFrom = 0
    /// A blob header was read; its payload (plus CRLF) is still arriving.
    private var pendingBlob: (type: UInt8, length: Int)?
    /// Open aggregates, innermost last.
    private var stack: [Frame] = []
    /// Attributes read at the top level, waiting for the reply they annotate.
    private var topAttributes: [[RESPPair]] = []
    /// Attributes read but not yet attached, at every level. Each one wraps its value in another `.attribute`, so
    /// they count toward the nesting limit: an unbounded run of `|0` would build a value too deep to free.
    private var pendingAttributes = 0
    /// Wire bytes and aggregate elements of the reply being parsed; reset when it completes.
    private var replyBytes = 0
    private var replyElements = 0
    private var failure: RESPError?

    private struct Frame {
        var kind: Aggregate
        var remaining: Int
        var items: [RESPValue] = []
        var attributes: [[RESPPair]] = []
    }

    private enum Aggregate { case array, set, push, map, attribute }

    public init(limits: RESPLimits = .standard) { self.limits = limits }

    /// Adds received bytes. Call `next()` until nil afterwards so the buffer holds at most one partial reply.
    public mutating func append(_ bytes: some Sequence<UInt8>) {
        guard failure == nil else { return }
        if position == buffer.count {
            // Everything was consumed: drop it, and let go of a large buffer left by a big reply.
            if buffer.capacity > 1_048_576 { buffer = [] } else { buffer.removeAll(keepingCapacity: true) }
            position = 0; lineScanFrom = 0
        } else if position >= 65_536 {
            buffer.removeSubrange(0..<position)
            lineScanFrom = max(0, lineScanFrom - position); position = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next complete reply, or nil until more bytes arrive.
    public mutating func next() throws(RESPError) -> RESPValue? {
        if let failure { throw failure }
        do { return try parse() } catch {
            failure = error
            throw error
        }
    }

    /// Bytes buffered plus element storage reserved by open aggregates; lets tests prove nothing was allocated
    /// for a declared but unreceived length.
    var reservedCapacity: Int { buffer.capacity + stack.reduce(0) { $0 + $1.items.capacity } }

    // MARK: - Parsing

    private mutating func parse() throws(RESPError) -> RESPValue? {
        while true {
            let value: RESPValue
            if let blob = pendingBlob {
                guard let payload = try readPayload(length: blob.length) else { return nil }
                pendingBlob = nil
                value = try Self.blob(type: blob.type, payload: payload)
            } else {
                guard let (type, line) = try readLine() else { return nil }
                guard let scalar = try header(type: type, line: line) else { continue }
                value = scalar
            }
            if let reply = try deliver(value) {
                replyBytes = 0; replyElements = 0
                return reply
            }
        }
    }

    /// Interprets one header line. Returns a finished scalar, or nil when it opened a blob or an aggregate.
    private mutating func header(type: UInt8, line: ArraySlice<UInt8>) throws(RESPError) -> RESPValue? {
        switch type {
        case Byte.plus: return .simpleString(Data(line))
        case Byte.minus: return .error(Data(line))
        case Byte.colon:
            guard let number = Self.integer(line) else { throw .protocolError(.invalidInteger) }
            return .integer(number)
        case Byte.comma:
            guard let number = Self.double(line) else { throw .protocolError(.invalidDouble) }
            return .double(number)
        case Byte.hash:
            guard line.count == 1, line.first == Byte.t || line.first == Byte.f else { throw .protocolError(.invalidBoolean) }
            return .boolean(line.first == Byte.t)
        case Byte.underscore:
            guard line.isEmpty else { throw .protocolError(.invalidNull) }
            return .null
        case Byte.paren:
            guard Self.isBigNumber(line) else { throw .protocolError(.invalidBigNumber) }
            return .bigNumber(String(decoding: line, as: UTF8.self))
        case Byte.dollar, Byte.bang, Byte.equals:
            let length = try Self.length(line)
            if length == -1 {
                // Only RESP2 bulk strings have a null spelling; `!-1` and `=-1` are malformed.
                guard type == Byte.dollar else { throw .protocolError(.invalidLength) }
                return .nullBulkString
            }
            if type == Byte.equals, length < 4 { throw .protocolError(.invalidVerbatim) }
            // Fail on the declared size before waiting for (or buffering) any of it.
            guard length <= limits.maxReplyBytes - replyBytes - 2 else { throw .limitExceeded(.replyBytes) }
            pendingBlob = (type, length)
            return nil
        default:
            guard let kind = Self.aggregate(type) else { throw .protocolError(.unknownType) }
            let count = try Self.length(line)
            if count == -1 {
                guard kind == .array else { throw .protocolError(.invalidLength) }
                return .nullArray
            }
            guard stack.count + pendingAttributes < limits.maxDepth else { throw .protocolError(.nestingTooDeep) }
            // Map and attribute counts are entries, each a key and a value.
            let pairs = kind == .map || kind == .attribute
            let budget = limits.maxElements - replyElements
            guard count <= (pairs ? budget / 2 : budget) else { throw .limitExceeded(.elements) }
            let elements = pairs ? count * 2 : count
            replyElements += elements
            if elements == 0 {
                guard kind != .attribute else { attach([]); return nil }
                return Self.build(kind, items: [])
            }
            // Reserve a little; the count is the server's claim, not memory to hand out.
            var frame = Frame(kind: kind, remaining: elements)
            frame.items.reserveCapacity(min(elements, 1_024))
            stack.append(frame)
            return nil
        }
    }

    /// Hands a finished value to its parent, closing every aggregate it completes. Returns the top-level reply
    /// once the outermost one closes.
    private mutating func deliver(_ value: RESPValue) throws(RESPError) -> RESPValue? {
        var value = value
        while true {
            guard var frame = stack.popLast() else {
                defer { pendingAttributes -= topAttributes.count; topAttributes = [] }
                return Self.annotate(value, with: topAttributes)
            }
            frame.items.append(Self.annotate(value, with: frame.attributes))
            pendingAttributes -= frame.attributes.count; frame.attributes = []
            frame.remaining -= 1
            guard frame.remaining == 0 else { stack.append(frame); return nil }
            if frame.kind == .attribute {
                // An attribute isn't an element of its parent; it waits for the next value at that level.
                attach(Self.pairs(frame.items))
                return nil
            }
            value = Self.build(frame.kind, items: frame.items)
        }
    }

    private mutating func attach(_ attribute: [RESPPair]) {
        pendingAttributes += 1
        if stack.isEmpty { topAttributes.append(attribute) } else { stack[stack.count - 1].attributes.append(attribute) }
    }

    // MARK: - Reading bytes

    /// The type byte and content of the line at `position`, or nil while its CRLF hasn't arrived.
    private mutating func readLine() throws(RESPError) -> (UInt8, ArraySlice<UInt8>)? {
        guard position < buffer.count else { return nil }
        let type = buffer[position]
        // Unknown type bytes fail at once, so a non-Redis peer (HTTP, SSH banner) is caught on its first byte.
        guard Self.isKnownType(type) else { throw .protocolError(.unknownType) }
        // Numeric headers are short; a long one is garbage, not a slow server.
        let lineCap = Self.isShortLineType(type) ? Self.maxShortLine : Int.max
        var index = max(lineScanFrom, position + 1)
        while index < buffer.count {
            switch buffer[index] {
            case Byte.cr:
                guard index + 1 < buffer.count else { lineScanFrom = index; return nil }
                guard buffer[index + 1] == Byte.lf else { throw .protocolError(.invalidLineEnding) }
                let line = buffer[(position + 1)..<index]
                guard line.count <= lineCap else { throw Self.shortLineError(type) }
                try consume(index + 2 - position)
                lineScanFrom = 0
                return (type, line)
            case Byte.lf: throw .protocolError(.invalidLineEnding)
            default: index += 1
            }
            if index - position - 1 > lineCap { throw Self.shortLineError(type) }
        }
        lineScanFrom = index
        // The whole unfinished tail belongs to this line, so it counts against the reply already.
        guard buffer.count - position <= limits.maxReplyBytes - replyBytes else { throw .limitExceeded(.replyBytes) }
        return nil
    }

    /// The blob payload at `position` and its CRLF, or nil while either is still arriving.
    private mutating func readPayload(length: Int) throws(RESPError) -> ArraySlice<UInt8>? {
        guard buffer.count - position - 2 >= length else { return nil }
        let end = position + length
        guard buffer[end] == Byte.cr, buffer[end + 1] == Byte.lf else { throw .protocolError(.invalidLineEnding) }
        let payload = buffer[position..<end]
        try consume(length + 2)
        return payload
    }

    private mutating func consume(_ count: Int) throws(RESPError) {
        position += count; replyBytes += count
        guard replyBytes <= limits.maxReplyBytes else { throw .limitExceeded(.replyBytes) }
    }

    // MARK: - Building values

    private static func blob(type: UInt8, payload: ArraySlice<UInt8>) throws(RESPError) -> RESPValue {
        switch type {
        case Byte.bang: return .blobError(Data(payload))
        case Byte.equals:
            // `fmt:` then the text.
            let start = payload.startIndex
            let format = payload[start..<(start + 3)]
            guard payload[start + 3] == Byte.colon, isVerbatimFormat(format) else { throw .protocolError(.invalidVerbatim) }
            return .verbatim(format: String(decoding: format, as: UTF8.self), Data(payload[(start + 4)...]))
        default: return .bulkString(Data(payload))
        }
    }

    private static func build(_ kind: Aggregate, items: [RESPValue]) -> RESPValue {
        switch kind {
        case .array: return .array(items)
        case .set: return .set(items)
        case .push: return .push(items)
        case .map, .attribute: return .map(pairs(items))
        }
    }

    private static func pairs(_ items: [RESPValue]) -> [RESPPair] {
        stride(from: 0, to: items.count, by: 2).map { RESPPair(items[$0], items[$0 + 1]) }
    }

    /// Wraps `value` in the attributes that preceded it, first one outermost (the order they were sent).
    private static func annotate(_ value: RESPValue, with attributes: [[RESPPair]]) -> RESPValue {
        attributes.reversed().reduce(value) { .attribute($1, $0) }
    }

    // MARK: - Grammar

    private static let maxShortLine = 32

    private static func isKnownType(_ type: UInt8) -> Bool {
        switch type {
        case Byte.plus, Byte.minus, Byte.colon, Byte.dollar, Byte.star, Byte.underscore, Byte.comma, Byte.hash, Byte.paren, Byte.bang, Byte.equals, Byte.percent,
            Byte.tilde, Byte.greater, Byte.pipe:
            return true
        default: return false
        }
    }

    /// Types whose line is a length, count, integer, boolean or null. Simple strings, errors, doubles and big
    /// numbers may legitimately be long and are bounded by the reply size instead.
    private static func isShortLineType(_ type: UInt8) -> Bool {
        switch type {
        case Byte.plus, Byte.minus, Byte.comma, Byte.paren: return false
        default: return true
        }
    }

    private static func shortLineError(_ type: UInt8) -> RESPError {
        switch type {
        case Byte.colon: return .protocolError(.invalidInteger)
        case Byte.hash: return .protocolError(.invalidBoolean)
        case Byte.underscore: return .protocolError(.invalidNull)
        default: return .protocolError(.invalidLength)
        }
    }

    private static func aggregate(_ type: UInt8) -> Aggregate? {
        switch type {
        case Byte.star: return .array
        case Byte.tilde: return .set
        case Byte.greater: return .push
        case Byte.percent: return .map
        case Byte.pipe: return .attribute
        default: return nil
        }
    }

    /// A length or count: decimal digits, or exactly `-1` (null; the caller decides if that's allowed).
    private static func length(_ line: ArraySlice<UInt8>) throws(RESPError) -> Int {
        if line.first == Byte.question { throw .protocolError(.streamedType) }
        if line.elementsEqual([Byte.minus, Byte.one]) { return -1 }
        guard line.first != Byte.plus, line.first != Byte.minus, let value = integer(line), let length = Int(exactly: value) else { throw .protocolError(.invalidLength) }
        return length
    }

    /// A signed 64-bit decimal with an optional sign; nil when empty, non-numeric or out of range.
    static func integer(_ line: ArraySlice<UInt8>) -> Int64? {
        var digits = line[...]
        let negative = digits.first == Byte.minus
        if negative || digits.first == Byte.plus { digits = digits.dropFirst() }
        guard !digits.isEmpty else { return nil }
        var result: Int64 = 0
        for byte in digits {
            guard Byte.isDigit(byte) else { return nil }
            // Accumulate negatively for negative numbers so Int64.min parses without overflowing.
            let digit = Int64(byte - Byte.zero)
            let (shifted, o1) = result.multipliedReportingOverflow(by: 10)
            let (next, o2) = negative ? shifted.subtractingReportingOverflow(digit) : shifted.addingReportingOverflow(digit)
            guard !o1, !o2 else { return nil }
            result = next
        }
        return result
    }

    /// `inf`, `-inf`, `nan`, or `[+-]digits[.digits][(e|E)[+-]digits]`. Checked here because `Double(String)`
    /// also accepts hex floats, `infinity` and other spellings no server sends.
    static func double(_ line: ArraySlice<UInt8>) -> Double? {
        let text = String(decoding: line, as: UTF8.self)
        switch text {
        case "inf", "+inf": return .infinity
        case "-inf": return -.infinity
        case "nan", "-nan": return .nan
        default: break
        }
        var rest = line[...]
        if rest.first == Byte.minus || rest.first == Byte.plus { rest = rest.dropFirst() }
        func digits() -> Bool {
            let count = rest.prefix(while: Byte.isDigit).count
            rest = rest.dropFirst(count)
            return count > 0
        }
        guard digits() else { return nil }
        if rest.first == Byte.dot { rest = rest.dropFirst(); guard digits() else { return nil } }
        if rest.first == Byte.e || rest.first == Byte.capitalE {
            rest = rest.dropFirst()
            if rest.first == Byte.minus || rest.first == Byte.plus { rest = rest.dropFirst() }
            guard digits() else { return nil }
        }
        guard rest.isEmpty else { return nil }
        return Double(text)
    }

    /// Three printable, non-space ASCII bytes (`txt`, `mkd`).
    static func isVerbatimFormat(_ format: some Collection<UInt8>) -> Bool {
        format.count == 3 && format.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    static func isBigNumber(_ line: ArraySlice<UInt8>) -> Bool {
        let digits = line.first == Byte.minus || line.first == Byte.plus ? line.dropFirst() : line
        return !digits.isEmpty && digits.allSatisfy(Byte.isDigit)
    }
}

/// ASCII bytes of the RESP grammar.
enum Byte {
    static let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
    static let plus = UInt8(ascii: "+"), minus = UInt8(ascii: "-"), colon = UInt8(ascii: ":"), dollar = UInt8(ascii: "$")
    static let star = UInt8(ascii: "*"), underscore = UInt8(ascii: "_"), comma = UInt8(ascii: ","), hash = UInt8(ascii: "#")
    static let paren = UInt8(ascii: "("), bang = UInt8(ascii: "!"), equals = UInt8(ascii: "="), percent = UInt8(ascii: "%")
    static let tilde = UInt8(ascii: "~"), greater = UInt8(ascii: ">"), pipe = UInt8(ascii: "|"), question = UInt8(ascii: "?")
    static let zero = UInt8(ascii: "0"), one = UInt8(ascii: "1"), dot = UInt8(ascii: "."), e = UInt8(ascii: "e"), capitalE = UInt8(ascii: "E")
    static let t = UInt8(ascii: "t"), f = UInt8(ascii: "f")
    static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= zero + 9 }
}

import Foundation

/// One RESP2 or RESP3 reply (INT-03). Strings stay bytes end to end: display escaping happens in the UI,
/// never here. The three nulls are kept apart so a reply re-encodes to the exact bytes the server sent.
public enum RESPValue: Sendable {
    // RESP2
    case simpleString(Data)
    case error(Data)
    case integer(Int64)
    case bulkString(Data)
    case array([RESPValue])
    /// RESP2 `$-1`.
    case nullBulkString
    /// RESP2 `*-1`.
    case nullArray
    // RESP3
    /// RESP3 `_`.
    case null
    case double(Double)
    case boolean(Bool)
    /// Decimal digits with an optional sign, kept as text because it may not fit any integer type.
    case bigNumber(String)
    case blobError(Data)
    /// `format` is the three-byte type hint (`txt`, `mkd`).
    case verbatim(format: String, Data)
    case map([RESPPair])
    case set([RESPValue])
    /// Out-of-band data (Pub/Sub messages, invalidations) on a RESP3 connection.
    case push([RESPValue])
    /// Attribute metadata (`|`) and the reply it annotates.
    indirect case attribute([RESPPair], RESPValue)

    /// True for every null spelling: RESP2 `$-1` / `*-1` and RESP3 `_`.
    public var isNull: Bool {
        switch self {
        case .null, .nullBulkString, .nullArray: return true
        default: return false
        }
    }
}

/// One map or attribute entry; RESP3 maps keep the server's order and may repeat keys.
public struct RESPPair: Sendable, Equatable {
    public var key: RESPValue
    public var value: RESPValue
    public init(_ key: RESPValue, _ value: RESPValue) { self.key = key; self.value = value }
}

extension RESPValue: Equatable {
    /// Structural equality, except that NaN equals NaN so decoded doubles compare like the bytes they came from.
    public static func == (lhs: RESPValue, rhs: RESPValue) -> Bool {
        switch (lhs, rhs) {
        case let (.simpleString(a), .simpleString(b)), let (.error(a), .error(b)), let (.bulkString(a), .bulkString(b)), let (.blobError(a), .blobError(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.array(a), .array(b)), let (.set(a), .set(b)), let (.push(a), .push(b)): return a == b
        case (.nullBulkString, .nullBulkString), (.nullArray, .nullArray), (.null, .null): return true
        case let (.double(a), .double(b)): return a == b || (a.isNaN && b.isNaN)
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.bigNumber(a), .bigNumber(b)): return a == b
        case let (.verbatim(f1, a), .verbatim(f2, b)): return f1 == f2 && a == b
        case let (.map(a), .map(b)): return a == b
        case let (.attribute(a1, v1), .attribute(a2, v2)): return a1 == a2 && v1 == v2
        default: return false
        }
    }
}

/// Bounds that keep a hostile server from exhausting memory or the stack (NFR-RS03, NFR-RL05).
public struct RESPLimits: Sendable, Equatable {
    /// Largest single reply, counted in wire bytes including headers and CRLFs.
    public var maxReplyBytes: Int
    /// Most aggregates (arrays, maps, sets, pushes, attributes) open at once.
    public var maxDepth: Int
    /// Most aggregate elements in one reply, summed across nesting (a map entry counts twice). Each element costs
    /// far more memory than its 3–4 wire bytes, so the byte cap alone would allow a gigabyte of `RESPValue`s.
    public var maxElements: Int

    public static let standard = RESPLimits(maxReplyBytes: 64 * 1_024 * 1_024, maxDepth: 128, maxElements: 4_194_304)

    public init(maxReplyBytes: Int, maxDepth: Int, maxElements: Int) {
        self.maxReplyBytes = maxReplyBytes; self.maxDepth = maxDepth; self.maxElements = maxElements
    }
}

/// What a malformed frame broke; carried by `RESPError.protocolError`.
public enum RESPViolation: String, Sendable {
    case unknownType
    /// An unknown type byte that starts a TLS record (alert 0x15, handshake 0x16): the server expects TLS.
    case tlsRecord
    case invalidLength, invalidInteger, invalidDouble, invalidBoolean, invalidBigNumber, invalidVerbatim, invalidNull
    /// A CR not followed by LF, a bare LF, or a bulk payload not followed by CRLF.
    case invalidLineEnding
    case nestingTooDeep
    /// RESP3 streamed strings and aggregates (`$?`, `*?`); no supported server sends them as replies.
    case streamedType
    /// Encoder only: a simple string or error containing CR/LF, which can't be framed.
    case unframeable
}

/// Which bound a reply broke; carried by `RESPError.limitExceeded`.
public enum RESPLimit: String, Sendable { case replyBytes, elements }

/// A codec failure. Either one is fatal for the connection: the parser stays failed and the caller closes it.
public enum RESPError: Error, Equatable, Sendable {
    case protocolError(RESPViolation)
    case limitExceeded(RESPLimit)

    /// The shared error code (`specs/02-architecture.md#errors`).
    public var code: String {
        switch self {
        case .protocolError: return "PROTOCOL_ERROR"
        case .limitExceeded: return "LIMIT_EXCEEDED"
        }
    }
}

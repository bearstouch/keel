import Foundation

/// The value viewer's four views (03 → Value editors, 08 Design → Editor). Hex is for reading only.
public enum ValueViewMode: String, CaseIterable, Sendable, Hashable {
    case text = "Text", json = "JSON", hex = "Hex", raw = "Raw"

    public var isEditable: Bool { self != .hex }
}

/// Why typed text can't become a value (Raw text that doesn't parse).
public struct ValueInputError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

// MARK: - Text

/// The Text view: UTF-8 as is, or — when the value has bytes that aren't printable UTF-8 text — an escaped form in which
/// `\` doubles and each such byte reads `\xNN`. The flag travels with the text, so an edit decodes back byte-exactly.
public enum ValueText {
    /// Plain text unless the value has invalid UTF-8 or a control character other than tab and newline (a `\r` would
    /// not survive the text view's line handling, a NUL would vanish), in which case the whole value is escaped.
    public static func render(_ value: Data) -> (text: String, escaped: Bool) {
        let bytes = [UInt8](value)
        if let plain = plainText(bytes) { return (plain, false) }
        var out = ""
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            // A valid sequence that isn't a control keeps its characters; anything else escapes byte by byte.
            if let length = UTF8Validation.sequenceLength(bytes, at: index),
                let scalar = UTF8Validation.scalar(bytes, at: index, length: length), !isEscapedControl(scalar)
            {
                if scalar == "\\" { out += "\\\\" } else { out.unicodeScalars.append(scalar) }
                index += length
            } else {
                out += hexEscape(bytes[index])
                index += 1
            }
        }
        return (out, true)
    }

    /// The bytes an edited text stands for. Escaped text turns `\\` into `\` and `\xNN` into its byte; any other
    /// backslash stays literal, so half-typed escapes never lose what was typed.
    public static func bytes(_ text: String, escaped: Bool) -> Data {
        guard escaped else { return Data(text.utf8) }
        let input = Array(text.utf8)
        var out = Data(capacity: input.count)
        var index = 0
        while index < input.count {
            if input[index] == 0x5C, index + 1 < input.count {
                if input[index + 1] == 0x5C { out.append(0x5C); index += 2; continue }
                if let byte = hexEscapedByte(input, at: index, end: input.count) { out.append(byte); index += 4; continue }
            }
            out.append(input[index]); index += 1
        }
        return out
    }

    private static func plainText(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        // Decoding repairs invalid UTF-8 with U+FFFD, so the bytes only match for valid input.
        guard text.utf8.elementsEqual(bytes), !text.unicodeScalars.contains(where: isEscapedControl) else { return nil }
        return text
    }

    private static func isEscapedControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t"
    }
}

// MARK: - Raw

/// The Raw view: the double-quoted redis-cli form (`"\xff\x00a"`), parsed back like redis-cli parses a quoted argument.
public enum ValueRaw {
    public static func render(_ value: Data) -> String { KeyDisplay.redisCliArgument(value) }

    /// `\xNN` with two hex digits is a byte, `\n \r \t \b \a` their controls, any other `\c` is `c` (sdssplitargs).
    public static func parse(_ text: String) -> Result<Data, ValueInputError> {
        let input = Array(text.utf8)
        var start = 0, end = input.count
        while start < end, isWhitespace(input[start]) { start += 1 }
        while end > start, isWhitespace(input[end - 1]) { end -= 1 }
        guard start < end, input[start] == 0x22 else {
            return .failure(ValueInputError("Raw values are written in double quotes, as redis-cli shows them."))
        }
        var out = Data(capacity: end - start)
        var index = start + 1
        while index < end {
            let byte = input[index]
            if byte == 0x22 {
                return index == end - 1 ? .success(out) : .failure(ValueInputError("Nothing may follow the closing quote."))
            }
            guard byte == 0x5C, index + 1 < end else { out.append(byte); index += 1; continue }
            let next = input[index + 1]
            if let byte = hexEscapedByte(input, at: index, end: end) { out.append(byte); index += 4; continue }
            switch next {
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x62: out.append(0x08)
            case 0x61: out.append(0x07)
            default: out.append(next)
            }
            index += 2
        }
        return .failure(ValueInputError("The closing quote is missing."))
    }
}

// MARK: - JSON

/// Where and why a value isn't JSON. Line and column count from 1; columns count characters (Unicode scalars).
public struct JSONSyntaxError: Error, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var message: String

    public init(line: Int, column: Int, message: String) { self.line = line; self.column = column; self.message = message }

    /// "Line 3, column 5: Expected “,” or “}”."
    public var description: String { "Line \(line), column \(column): \(message)" }
}

/// Pretty-printed JSON with its tokens for syntax colors (08 Design: keys, strings, literals).
public struct PrettyJSON: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case key, string, literal }

    /// A token's place in `text`, in UTF-16 offsets (what `NSAttributedString` ranges count).
    public struct Span: Sendable, Equatable {
        public var kind: Kind
        public var location: Int
        public var length: Int
    }

    public var text: String
    public var spans: [Span]
}

/// A strict RFC 8259 validator and pretty-printer. It keeps keys in their order and numbers and strings exactly as
/// written (Foundation's parser does neither), so the JSON view shows the value's own tokens, re-indented.
public enum ValueJSON {
    /// Deeper documents are reported as an error instead of risking the stack.
    public static let maxDepth = 512

    /// The viewer opens in JSON on its own only for an object or array that parses; `42` or `"x"` stay Text.
    public static func detect(_ value: Data) -> Bool {
        guard let first = value.first(where: { !isWhitespace($0) }), first == 0x7B || first == 0x5B else { return false }
        return validate(value) == nil
    }

    /// Nil for valid JSON.
    public static func validate(_ value: Data) -> JSONSyntaxError? {
        var parser = JSONParser(bytes: [UInt8](value), pretty: false)
        do throws(JSONSyntaxError) { try parser.document() } catch { return error }
        return nil
    }

    public static func pretty(_ value: Data) -> Result<PrettyJSON, JSONSyntaxError> {
        var parser = JSONParser(bytes: [UInt8](value), pretty: true)
        do throws(JSONSyntaxError) { try parser.document() } catch { return .failure(error) }
        return .success(PrettyJSON(text: parser.out, spans: parser.spans))
    }
}

/// Recursive descent over UTF-8 bytes; with `pretty`, it writes two-space-indented output as it goes.
private struct JSONParser {
    let bytes: [UInt8]
    let pretty: Bool
    var index = 0
    var out = ""
    var spans: [PrettyJSON.Span] = []
    /// `out`'s length in UTF-16, kept alongside so spans don't recount the text.
    var utf16 = 0

    init(bytes: [UInt8], pretty: Bool) { self.bytes = bytes; self.pretty = pretty }

    mutating func document() throws(JSONSyntaxError) {
        skipSpace()
        try value(depth: 0)
        skipSpace()
        guard index == bytes.count else { throw failure("Unexpected text after the JSON value.") }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipSpace() { while index < bytes.count, isWhitespace(bytes[index]) { index += 1 } }

    private mutating func value(depth: Int) throws(JSONSyntaxError) {
        switch peek {
        case 0x7B?: try container(depth: depth, close: 0x7D)
        case 0x5B?: try container(depth: depth, close: 0x5D)
        case 0x22?: try string(.string)
        case 0x2D?, (0x30...0x39)?: try number()
        case 0x74?: try word("true")
        case 0x66?: try word("false")
        case 0x6E?: try word("null")
        default: throw failure(index < bytes.count ? "Expected a value." : "Expected a value, found the end of the text.")
        }
    }

    /// An object (`close` is `}`) or an array (`]`).
    private mutating func container(depth: Int, close: UInt8) throws(JSONSyntaxError) {
        guard depth < ValueJSON.maxDepth else { throw failure("Nesting is deeper than \(ValueJSON.maxDepth) levels.") }
        let isObject = close == 0x7D
        emit(isObject ? "{" : "[")
        index += 1
        skipSpace()
        if peek == close { index += 1; emit(isObject ? "}" : "]"); return }
        while true {
            newline(depth + 1)
            if isObject {
                guard peek == 0x22 else { throw failure("Expected a string key.") }
                try string(.key)
                skipSpace()
                guard peek == 0x3A else { throw failure("Expected “:” after the key.") }
                index += 1; emit(": ")
                skipSpace()
            }
            try value(depth: depth + 1)
            skipSpace()
            if peek == 0x2C { index += 1; emit(","); skipSpace(); continue }
            guard peek == close else { throw failure(isObject ? "Expected “,” or “}”." : "Expected “,” or “]”.") }
            index += 1
            newline(depth); emit(isObject ? "}" : "]")
            return
        }
    }

    private mutating func string(_ kind: PrettyJSON.Kind) throws(JSONSyntaxError) {
        let start = index
        index += 1
        while true {
            guard let byte = peek else { throw failure("The string isn't closed.", at: start) }
            switch byte {
            case 0x22:
                index += 1
                token(kind, from: start)
                return
            case 0x5C:
                index += 1
                switch peek {
                case 0x22?, 0x5C?, 0x2F?, 0x62?, 0x66?, 0x6E?, 0x72?, 0x74?: index += 1
                case 0x75?:
                    index += 1
                    for _ in 0..<4 {
                        guard let digit = peek, hexDigit(digit) != nil else { throw failure("Expected four hex digits after “\\u”.") }
                        index += 1
                    }
                default: throw failure("Invalid escape in a string.")
                }
            case 0..<0x20: throw failure("Control characters must be escaped in a string.")
            case 0x80...:
                guard let length = UTF8Validation.sequenceLength(bytes, at: index) else { throw failure("Invalid UTF-8 in a string.") }
                index += length
            default: index += 1
            }
        }
    }

    private mutating func number() throws(JSONSyntaxError) {
        let start = index
        if peek == 0x2D { index += 1 }
        if peek == 0x30 {
            index += 1
        } else {
            guard digits() > 0 else { throw failure("Expected a digit.") }
        }
        if peek == 0x2E {
            index += 1
            guard digits() > 0 else { throw failure("Expected a digit after the decimal point.") }
        }
        if peek == 0x65 || peek == 0x45 {
            index += 1
            if peek == 0x2B || peek == 0x2D { index += 1 }
            guard digits() > 0 else { throw failure("Expected a digit in the exponent.") }
        }
        token(.literal, from: start)
    }

    private mutating func digits() -> Int {
        let start = index
        while let byte = peek, (0x30...0x39).contains(byte) { index += 1 }
        return index - start
    }

    private mutating func word(_ literal: String) throws(JSONSyntaxError) {
        let start = index
        for expected in literal.utf8 {
            guard peek == expected else { throw failure("Expected a value.", at: start) }
            index += 1
        }
        token(.literal, from: start)
    }

    // MARK: Output

    private mutating func emit(_ text: String) {
        guard pretty else { return }
        out += text; utf16 += text.utf16.count
    }

    private mutating func newline(_ depth: Int) { emit("\n" + String(repeating: "  ", count: depth)) }

    /// Copies the token's bytes as written (already validated UTF-8) and records its span.
    private mutating func token(_ kind: PrettyJSON.Kind, from start: Int) {
        guard pretty else { return }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        let length = text.utf16.count
        spans.append(PrettyJSON.Span(kind: kind, location: utf16, length: length))
        out += text; utf16 += length
    }

    // MARK: Errors

    private func failure(_ message: String, at offset: Int? = nil) -> JSONSyntaxError {
        let offset = min(offset ?? index, bytes.count)
        var line = 1, column = 1
        for byte in bytes[0..<offset] {
            if byte == 0x0A {
                line += 1; column = 1
            } else if byte & 0xC0 != 0x80 {
                // Continuation bytes belong to the character before them.
                column += 1
            }
        }
        return JSONSyntaxError(line: line, column: column, message: message)
    }
}

// MARK: - Hex

/// The Hex view: 16 bytes a line as offset, hex (two groups of eight) and ASCII, like `hexdump -C`. Lines are made on
/// demand, so a 1 MiB value costs only the lines on screen.
public enum HexLayout {
    public static let bytesPerLine = 16

    public struct Line: Sendable, Equatable {
        /// Eight hex digits: "00000010".
        public var offset: String
        /// "48 65 6c 6c 6f 20 77 6f  72 6c 64", padded to full width so the ASCII column lines up.
        public var hex: String
        /// Printable ASCII as is, every other byte ".".
        public var ascii: String
    }

    public static func lineCount(_ byteCount: Int) -> Int { (byteCount + bytesPerLine - 1) / bytesPerLine }

    /// Line `number` of `value`; past the end it is empty.
    public static func line(_ number: Int, of value: Data) -> Line {
        let first = number * bytesPerLine
        let count = max(0, min(bytesPerLine, value.count - first))
        var hex = "", ascii = ""
        hex.reserveCapacity(49); ascii.reserveCapacity(bytesPerLine)
        for column in 0..<bytesPerLine {
            if column > 0 { hex += column == 8 ? "  " : " " }
            guard column < count else { hex += "  "; continue }
            let byte = value[value.startIndex + first + column]
            hex += hexByte(byte)
            ascii.unicodeScalars.append((0x20...0x7E).contains(byte) ? Unicode.Scalar(byte) : ".")
        }
        return Line(offset: String(format: "%08x", first), hex: hex, ascii: ascii)
    }
}

// MARK: - Viewer state

/// One value in the viewer: the chosen view, its text and what it says about the value (03 → Value editors). Edits in
/// Text, JSON and Raw decode back to bytes; `bytes` is the value the editor saves.
public struct ValueViewerState: Sendable, Equatable {
    public private(set) var mode: ValueViewMode
    /// The value shown: as opened, or as the last edit that could be decoded.
    public private(set) var bytes: Data
    /// What Text, JSON and Raw show and edit; empty in Hex, which draws lines from `bytes`.
    public private(set) var text = ""
    /// Text and invalid JSON in escaped form (see `ValueText`): edits decode with the same rule.
    public private(set) var escaped = false
    /// JSON view only: the parse error of `bytes`, nil when they are valid JSON.
    public private(set) var jsonError: JSONSyntaxError?
    /// JSON view only: syntax colors for `text` as rendered; dropped after an edit, when they would be out of place.
    public private(set) var jsonSpans: [PrettyJSON.Span] = []
    /// Raw view only: why the typed text doesn't parse. `bytes` keeps the last text that did.
    public private(set) var rawError: ValueInputError?

    /// `mode` nil chooses: JSON when the value is an object or array that parses, else Text.
    public init(bytes: Data, mode: ValueViewMode?) {
        self.bytes = bytes
        self.mode = mode ?? (ValueJSON.detect(bytes) ? .json : .text)
        render()
    }

    /// The "✓ Valid JSON" note.
    public var isValidJSON: Bool { mode == .json && jsonError == nil }

    /// Why Save is refused while this view shows: invalid JSON in the JSON view (FR-ED01: only Text may save it) or Raw
    /// text that doesn't parse. Nil when saving is fine.
    public var saveBlock: String? {
        if mode == .json, jsonError != nil { return "Invalid JSON can't be saved from JSON view. Switch to Text to save it as is." }
        if mode == .raw, let rawError { return rawError.message }
        return nil
    }

    /// Switches views; the new view renders the current bytes, so a Raw text that didn't parse is dropped.
    public mutating func show(_ mode: ValueViewMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        render()
    }

    /// The user's edit of `text`. Returns the new bytes when they differ from the last ones (nil for Raw text that
    /// doesn't parse, or an edit that leaves the bytes as they were).
    @discardableResult public mutating func edit(_ text: String) -> Data? {
        guard mode.isEditable else { return nil }
        self.text = text
        let decoded: Data
        switch mode {
        case .raw:
            switch ValueRaw.parse(text) {
            case .success(let value): rawError = nil; decoded = value
            case .failure(let error): rawError = error; return nil
            }
        case .json:
            decoded = ValueText.bytes(text, escaped: escaped)
            jsonError = ValueJSON.validate(decoded); jsonSpans = []
        case .text, .hex:
            decoded = ValueText.bytes(text, escaped: escaped)
        }
        guard decoded != bytes else { return nil }
        bytes = decoded
        return decoded
    }

    private mutating func render() {
        jsonError = nil; jsonSpans = []; rawError = nil; escaped = false
        switch mode {
        case .text: (text, escaped) = ValueText.render(bytes)
        case .raw: text = ValueRaw.render(bytes)
        case .hex: text = ""
        case .json:
            switch ValueJSON.pretty(bytes) {
            case .success(let pretty): text = pretty.text; jsonSpans = pretty.spans
            case .failure(let error): jsonError = error; (text, escaped) = ValueText.render(bytes)
            }
        }
    }
}

/// The view chosen per key pattern for the session (03 → Value editors). Kept in memory only: patterns come from key
/// names, which are never persisted.
public struct ValueViewerMemory: Sendable {
    /// User choices only, but a cap keeps a long session bounded.
    public static let capacity = 1_000

    private var modes: [Data: ValueViewMode] = [:]

    public init() {}

    /// The key's namespace and `*` (`user:42` → `user:*`, `a::b::c` → `a::b::*`), or the key itself without a separator.
    public static func pattern(of key: Data, separator: NamespaceSeparator) -> Data {
        guard let range = key.range(of: separator.bytes, options: .backwards) else { return key }
        return key[key.startIndex..<range.upperBound] + Data("*".utf8)
    }

    public func mode(for pattern: Data) -> ValueViewMode? { modes[pattern] }

    public mutating func remember(_ mode: ValueViewMode, for pattern: Data) {
        if modes[pattern] == nil, modes.count >= Self.capacity { modes.removeAll(keepingCapacity: true) }
        modes[pattern] = mode
    }
}

// MARK: - Helpers

/// Space, tab, newline and carriage return: what JSON allows between tokens and Raw trims around the quotes.
private func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

/// The byte of a `\xNN` escape whose backslash is at `index`, when two hex digits follow before `end`.
private func hexEscapedByte(_ input: [UInt8], at index: Int, end: Int) -> UInt8? {
    guard index + 3 < end, input[index + 1] == 0x78, let high = hexDigit(input[index + 2]), let low = hexDigit(input[index + 3]) else { return nil }
    return high << 4 | low
}

private func hexDigit(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
    }
}

private let hexDigits = Array("0123456789abcdef".unicodeScalars)

private func hexByte(_ byte: UInt8) -> String { String(hexDigits[Int(byte >> 4)]) + String(hexDigits[Int(byte & 0xF)]) }

private func hexEscape(_ byte: UInt8) -> String { "\\x" + hexByte(byte) }

/// Well-formed UTF-8 per Unicode table 3-7: no overlongs, surrogates or scalars past U+10FFFF.
private enum UTF8Validation {
    /// The length of the well-formed sequence starting at `index`, or nil.
    static func sequenceLength(_ bytes: [UInt8], at index: Int) -> Int? {
        let lead = bytes[index]
        if lead < 0x80 { return 1 }
        let (length, second): (Int, ClosedRange<UInt8>)
        switch lead {
        case 0xC2...0xDF: (length, second) = (2, 0x80...0xBF)
        case 0xE0: (length, second) = (3, 0xA0...0xBF)
        case 0xE1...0xEC, 0xEE...0xEF: (length, second) = (3, 0x80...0xBF)
        case 0xED: (length, second) = (3, 0x80...0x9F)
        case 0xF0: (length, second) = (4, 0x90...0xBF)
        case 0xF1...0xF3: (length, second) = (4, 0x80...0xBF)
        case 0xF4: (length, second) = (4, 0x80...0x8F)
        default: return nil
        }
        guard index + length <= bytes.count, second.contains(bytes[index + 1]) else { return nil }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) { return nil }
        return length
    }

    /// The scalar of a sequence `sequenceLength` accepted.
    static func scalar(_ bytes: [UInt8], at index: Int, length: Int) -> Unicode.Scalar? {
        let lead = UInt32(bytes[index])
        var value: UInt32 = length == 1 ? lead : lead & (0xFF >> (length + 1))
        for offset in 1..<length { value = value << 6 | UInt32(bytes[index + offset] & 0x3F) }
        return Unicode.Scalar(value)
    }
}

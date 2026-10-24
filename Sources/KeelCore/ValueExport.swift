import Foundation

/// Export and Copy Value for the open key (FR-ED15). A string exports its raw bytes, unchanged; a collection exports
/// JSON. Byte strings in the JSON are text when they are valid UTF-8, else `{"base64": "…"}`, so no byte is lost.
public enum ValueExport {
    /// The file's bytes for `rows` as the editor loaded them; nil for a type without rows to export (module types).
    public static func data(key: Data, type: KeyType, rows: [EditorRow]) -> Data? {
        if type == .string { return stringValue(rows) }
        guard let (name, body) = json(type, rows) else { return nil }
        let document = Document(key: Bytes(key), type: name, body: body)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(document)
    }

    /// Copy Value: a string's text when it is valid UTF-8, else its redis-cli escaping (which parses back to the same
    /// bytes); a collection's export JSON.
    public static func copyText(key: Data, type: KeyType, rows: [EditorRow]) -> String? {
        guard type == .string else { return data(key: key, type: type, rows: rows).map { String(decoding: $0, as: UTF8.self) } }
        let bytes = stringValue(rows)
        return Bytes.utf8(bytes) ?? KeyDisplay.redisCliArgument(bytes)
    }

    /// The save panel's suggestion: the key's last segment with path characters replaced, `.json` for collections, `.txt`
    /// for a UTF-8 string and `.bin` for any other.
    public static func suggestedFileName(key: Data, type: KeyType, rows: [EditorRow], separator: NamespaceSeparator = .default) -> String {
        let leaf = String(decoding: key.split(separator: separator.bytes).last ?? key, as: UTF8.self)
        let safe = String(leaf.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "_" }.prefix(100))
        let base = safe.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "value" : safe
        if type != .string { return base + ".json" }
        return base + (Bytes.utf8(stringValue(rows)) != nil ? ".txt" : ".bin")
    }

    /// A string key's editor holds one row, its value; an empty value when none was loaded.
    private static func stringValue(_ rows: [EditorRow]) -> Data { rows.first?.value ?? Data() }

    /// Writes `data` to `url` byte for byte, replacing the file atomically (a failed write leaves the old file).
    public static func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }

    // MARK: - JSON

    private struct Document: Encodable {
        var key: Bytes
        var type: String
        var body: Body

        enum CodingKeys: String, CodingKey { case key, type }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(type, forKey: .type)
            try body.encode(to: encoder)
        }
    }

    /// The type's rows under one name: hash `fields`, list `items`, set and sorted set `members`, stream `entries`.
    private enum Body {
        case fields([Pair]), items([Bytes]), members([Bytes]), scored([Scored]), entries([Entry])

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .fields(let pairs): try container.encode(pairs, forKey: Key(stringValue: "fields"))
            case .items(let items): try container.encode(items, forKey: Key(stringValue: "items"))
            case .members(let members): try container.encode(members, forKey: Key(stringValue: "members"))
            case .scored(let members): try container.encode(members, forKey: Key(stringValue: "members"))
            case .entries(let entries): try container.encode(entries, forKey: Key(stringValue: "entries"))
            }
        }
    }

    private struct Pair: Encodable { var field: Bytes; var value: Bytes }
    private struct Entry: Encodable { var id: Bytes; var fields: [Pair] }

    private struct Scored: Encodable {
        var member: Bytes
        /// The row's score text, as the editor shows it.
        var score: Data

        enum CodingKeys: String, CodingKey { case member, score }

        /// JSON has no infinities, so `inf` / `-inf` stay strings, as Redis spells them; finite scores are numbers.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(member, forKey: .member)
            if let value = SortedSetEditor.parseScore(String(decoding: score, as: UTF8.self)), value.isFinite {
                try container.encode(value, forKey: .score)
            } else {
                try container.encode(Bytes(score), forKey: .score)
            }
        }
    }

    /// A byte string: a JSON string when it is valid UTF-8, else `{"base64": "…"}`.
    struct Bytes: Encodable {
        var data: Data
        init(_ data: Data) { self.data = data }

        static func utf8(_ data: Data) -> String? {
            let text = String(decoding: data, as: UTF8.self)
            return Data(text.utf8) == data ? text : nil
        }

        func encode(to encoder: Encoder) throws {
            if let text = Self.utf8(data) {
                var container = encoder.singleValueContainer()
                try container.encode(text)
            } else {
                try ["base64": data.base64EncodedString()].encode(to: encoder)
            }
        }
    }

    /// The type's name as Redis's `TYPE` spells it, and its rows.
    private static func json(_ type: KeyType, _ rows: [EditorRow]) -> (String, Body)? {
        switch type {
        case .hash: return ("hash", .fields(rows.map { Pair(field: Bytes($0.id), value: Bytes($0.value)) }))
        // Rows are named by index; sorting keeps head-to-tail order whatever order they were loaded in.
        case .list: return ("list", .items(rows.sorted { (ListEditor.index(of: $0.id) ?? 0) < (ListEditor.index(of: $1.id) ?? 0) }.map { Bytes($0.value) }))
        case .set: return ("set", .members(rows.map { Bytes($0.id) }))
        case .zset: return ("zset", .scored(rows.map { Scored(member: Bytes($0.id), score: $0.value) }))
        case .stream:
            let entries = rows.map { row in Entry(id: Bytes(row.id), fields: (StreamEditor.fields(of: row) ?? []).map { Pair(field: Bytes($0.field), value: Bytes($0.value)) }) }
            return ("stream", .entries(entries))
        case .string, .unknown, .other: return nil
        }
    }
}

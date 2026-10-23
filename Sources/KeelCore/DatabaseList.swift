import Foundation
import KeelRESP

/// One database as the switcher lists it (FR-KB08).
public struct DatabaseEntry: Sendable, Equatable, Identifiable {
    public var index: Int
    /// `keys` from `INFO keyspace`; nil for a database the server didn't list there, which means it holds no keys.
    public var keys: Int?
    /// Keys with an expiry, from the same line.
    public var expires: Int?

    public init(index: Int, keys: Int? = nil, expires: Int? = nil) { self.index = index; self.keys = keys; self.expires = expires }

    public var id: Int { index }
    /// "db3", as the picker's button shows it.
    public var name: String { "db\(index)" }
    /// The menu row: "db3 · 1,204 keys"; an empty database is its name alone, so rows stay quiet.
    public var title: String { keys.map { "\(name) · \(Self.keysText($0))" } ?? name }
    /// What VoiceOver reads: "db3, 1,204 keys" or "db3, empty".
    public var accessibilityLabel: String { "\(name), \(keys.map(Self.keysText) ?? "empty")" }

    private static func keysText(_ count: Int) -> String { "\(KeyIndexFooter.grouped(count)) \(count == 1 ? "key" : "keys")" }
}

/// Keys and expiring keys of one `dbN:` line of `INFO keyspace`.
public struct KeyspaceCounts: Sendable, Equatable {
    public var keys: Int
    public var expires: Int

    public init(keys: Int, expires: Int = 0) { self.keys = keys; self.expires = expires }
}

/// The databases the switcher offers and their key counts (FR-KB08): db0–db15, or the server's `databases` count when
/// `CONFIG GET databases` was permitted, with counts from `INFO keyspace`. A cluster-mode server has db0 only.
public struct DatabaseList: Sendable, Equatable {
    /// Redis's default `databases`, used when the server wouldn't say.
    public static let defaultCount = 16
    /// A server may be configured with any number of databases; the menu lists at most this many so it stays bounded.
    public static let maximumCount = 4_096

    public var entries: [DatabaseEntry]

    /// `databaseCount` is the server's `databases` (nil when unknown). A database `INFO keyspace` lists past it — an
    /// unknown count that isn't 16 — is still offered, so no database with keys is hidden (up to `maximumCount`).
    public init(keyspace: [Int: KeyspaceCounts], databaseCount: Int?, mode: ServerMode) {
        let count: Int
        if mode == .cluster {
            // Cluster mode has only db0 (Redis refuses SELECT there; cluster browsing beyond one node is later work).
            count = 1
        } else {
            let highest = keyspace.keys.filter { $0 < Self.maximumCount }.max().map { $0 + 1 } ?? 0
            count = min(max(databaseCount ?? Self.defaultCount, highest, 1), Self.maximumCount)
        }
        entries = (0..<count).map { DatabaseEntry(index: $0, keys: keyspace[$0]?.keys, expires: keyspace[$0]?.expires) }
    }

    public func entry(_ database: Int) -> DatabaseEntry? { entries.indices.contains(database) ? entries[database] : nil }

    /// `dbN:keys=…,expires=…,avg_ttl=…` lines (Redis 7.4+ adds `subexpiry`; Dragonfly and Valkey use the same form).
    /// Other lines, malformed counts and negative indices are skipped.
    public static func parseKeyspace(_ text: String) -> [Int: KeyspaceCounts] {
        var counts: [Int: KeyspaceCounts] = [:]
        for (name, value) in InfoFields.parse(text) {
            guard name.hasPrefix("db"), let index = Int(name.dropFirst(2)), index >= 0, String(index) == name.dropFirst(2) else { continue }
            var fields: [Substring: Int] = [:]
            for pair in value.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let number = Int(parts[1]) { fields[parts[0]] = number }
            }
            guard let keys = fields["keys"], keys >= 0 else { continue }
            counts[index] = KeyspaceCounts(keys: keys, expires: max(fields["expires"] ?? 0, 0))
        }
        return counts
    }

    /// The `databases` value of a `CONFIG GET databases` reply: `[name, value]` on RESP2, a one-entry map on RESP3.
    /// Nil for an error (an ACL without `CONFIG`), an odd reply or a count below 1.
    public static func databaseCount(configReply reply: RESPValue) -> Int? {
        let value: RESPValue?
        switch reply {
        case .array(let items) where items.count == 2: value = items[1]
        case .map(let pairs) where pairs.count == 1: value = pairs[0].value
        default: value = nil
        }
        guard case .bulkString(let bytes)? = value, let count = Int(String(decoding: bytes, as: UTF8.self)), count >= 1 else { return nil }
        return count
    }

    /// Asks `CONFIG GET databases` once at session setup, best effort, the way the capability probes run: on the
    /// session's connection, marked a read. `CONFIG` is admin for the console and agents, so this fixed, read-only
    /// probe is the only `CONFIG` Keel sends by itself; any failure gives nil and the switcher offers db0–db15.
    public static func probeCount(send: CapabilityProbe.Send) async -> Int? {
        let reply: RESPValue
        do throws(RedisError) { reply = try await send([Data("CONFIG".utf8), Data("GET".utf8), Data("databases".utf8)]) } catch { return nil }
        return databaseCount(configReply: reply)
    }

    /// Loads the counts with `INFO keyspace` through the data path (`.browser` origin, allowed on read-only profiles).
    public static func load(service: DataCommandService, context: DataContext, databaseCount: Int?, mode: ServerMode) async -> Result<DatabaseList, KeyIndexError> {
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await service.execute(.operation(.info(section: Data("keyspace".utf8))), origin: .browser, context: context).reply
        } catch {
            return .failure(KeyIndexError(code: error.code, message: KeyIndex.describe(error, command: "INFO")))
        }
        switch reply {
        case .error(let text), .blobError(let text): return .failure(KeyIndex.serverError(text))
        default:
            guard let text = InfoFields.text(of: reply) else {
                return .failure(KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's INFO reply wasn't text."))
            }
            return .success(DatabaseList(keyspace: parseKeyspace(text), databaseCount: databaseCount, mode: mode))
        }
    }
}

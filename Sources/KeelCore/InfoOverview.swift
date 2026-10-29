import Foundation

/// One Info tile (FR-SI01): "Memory 1.2 of 4 GB" with a bar, "Clients 48", "Operations 3,412 per sec", "Uptime 12 days".
public struct InfoTile: Sendable, Equatable, Identifiable {
    public var label: String
    /// "—" when the server didn't send the field.
    public var value: String
    public var unit: String
    /// The memory bar's fill, 0…1; nil for tiles without a bar (and memory without a `maxmemory` limit).
    public var fraction: Double?

    public init(label: String, value: String, unit: String = "", fraction: Double? = nil) {
        self.label = label; self.value = value; self.unit = unit; self.fraction = fraction
    }

    public var id: String { label }
    public var isAvailable: Bool { value != InfoOverview.missing }
    /// What VoiceOver reads: "Memory, 1.2 of 4 GB, 30 percent", "Clients, unavailable".
    public var accessibilityLabel: String {
        guard isAvailable else { return "\(label), unavailable" }
        let amount = unit.isEmpty ? value : "\(value) \(unit)"
        return fraction.map { "\(label), \(amount), \(Int(($0 * 100).rounded())) percent" } ?? "\(label), \(amount)"
    }
}

/// One `dbN:` line of the Keyspace section (FR-SI04): keys, expiring keys and the average TTL.
public struct InfoDatabase: Sendable, Equatable, Identifiable {
    public var index: Int
    public var keys: Int
    public var expires: Int
    /// `avg_ttl` in milliseconds; 0 when no key expires (or the server doesn't compute it).
    public var averageTTL: Int

    public init(index: Int, keys: Int, expires: Int = 0, averageTTL: Int = 0) {
        self.index = index; self.keys = keys; self.expires = expires; self.averageTTL = averageTTL
    }

    public var id: Int { index }
    public var name: String { "db\(index)" }
    /// "1,204,551 keys", then "· 1,000 expiring, avg TTL 2 h" only when some keys expire (DS-01: show less).
    public var summary: String {
        let keys = "\(KeyIndexFooter.grouped(self.keys)) \(self.keys == 1 ? "key" : "keys")"
        guard expires > 0 else { return keys }
        let ttl = averageTTL > 0 ? ", avg TTL \(InfoOverview.shortDuration(milliseconds: averageTTL))" : ""
        return "\(keys) · \(KeyIndexFooter.grouped(expires)) expiring\(ttl)"
    }
}

/// One Health row (FR-SI01): replication, last save, hit ratio.
public struct InfoHealthItem: Sendable, Equatable, Identifiable {
    public var label: String
    public var value: String

    public init(label: String, value: String) { self.label = label; self.value = value }

    public var id: String { label }
}

/// The Info overview of one `INFO` reply (FR-SI01, FR-SI02): every value comes from that reply, so the tiles match it.
public struct InfoOverview: Sendable, Equatable {
    /// What a tile or row shows for a field the server didn't send.
    public static let missing = "—"
    public static let unavailable = "unavailable"

    public var tiles: [InfoTile]
    public var databases: [InfoDatabase]
    public var health: [InfoHealthItem]

    /// `now` dates the last save ("6 minutes ago"); injected so tests are deterministic.
    public init(report: InfoReport, now: Date) {
        tiles = [
            Self.memory(report), Self.count("Clients", report["connected_clients"]), Self.count("Operations", report["instantaneous_ops_per_sec"], unit: "per sec"),
            Self.uptime(report)
        ]
        databases = Self.databases(report.section("Keyspace"))
        health = [
            InfoHealthItem(label: "Replication", value: Self.replication(report)),
            InfoHealthItem(label: "Last save", value: Self.lastSave(report, now: now)),
            InfoHealthItem(label: "Hit ratio", value: Self.hitRatio(report))
        ]
    }

    // MARK: - Tiles

    /// `used_memory` in the unit of `maxmemory` ("1.2 of 4 GB", bar 30%); without a limit, "1.2 GB" and no bar.
    static func memory(_ report: InfoReport) -> InfoTile {
        guard let used = report["used_memory"].flatMap(Int64.init), used >= 0 else { return InfoTile(label: "Memory", value: missing) }
        guard let limit = report["maxmemory"].flatMap(Int64.init), limit > 0 else {
            let (value, unit) = bytes(used, unitOf: used)
            return InfoTile(label: "Memory", value: value, unit: unit)
        }
        let (value, _) = bytes(used, unitOf: limit), (total, unit) = bytes(limit, unitOf: limit)
        return InfoTile(label: "Memory", value: value, unit: "of \(total) \(unit)", fraction: min(Double(used) / Double(limit), 1))
    }

    /// A missing field drops the unit too: the tile reads "— unavailable", not "— per sec".
    static func count(_ label: String, _ field: String?, unit: String = "") -> InfoTile {
        guard let value = field.flatMap(Int.init), value >= 0 else { return InfoTile(label: label, value: missing) }
        return InfoTile(label: label, value: KeyIndexFooter.grouped(value), unit: unit)
    }

    /// The largest whole unit: "42 seconds", "5 minutes", "3 hours", "12 days".
    static func uptime(_ report: InfoReport) -> InfoTile {
        guard let seconds = report["uptime_in_seconds"].flatMap(Int.init), seconds >= 0 else { return InfoTile(label: "Uptime", value: missing) }
        let (value, unit) = largestUnit(seconds: seconds)
        return InfoTile(label: "Uptime", value: KeyIndexFooter.grouped(value), unit: value == 1 ? unit : unit + "s")
    }

    /// 1024-based, as Redis's `*_human` fields: the unit is the one `reference` reads best in, so used and limit match.
    static func bytes(_ value: Int64, unitOf reference: Int64) -> (value: String, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var exponent = 0, scaled = Double(max(reference, 0))
        while scaled >= 1024, exponent < units.count - 1 { scaled /= 1024; exponent += 1 }
        let amount = Double(value) / pow(1024, Double(exponent))
        // One decimal, dropped when it is zero ("4 GB", "1.2 GB"); bytes are whole. No `Int64(Double)`: a hostile
        // `used_memory` near Int64.max rounds to 2^63 as a double, which would trap.
        let text = exponent == 0 ? String(value) : amount == amount.rounded() ? String(format: "%.0f", amount) : String(format: "%.1f", amount)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text, units[exponent])
    }

    private static func largestUnit(seconds: Int) -> (Int, String) {
        if seconds >= 86_400 { return (seconds / 86_400, "day") }
        if seconds >= 3_600 { return (seconds / 3_600, "hour") }
        if seconds >= 60 { return (seconds / 60, "minute") }
        return (seconds, "second")
    }

    /// "2 h", "45 min", "30 s" for the average TTL.
    static func shortDuration(milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        if seconds >= 86_400 { return "\(seconds / 86_400) d" }
        if seconds >= 3_600 { return "\(seconds / 3_600) h" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(max(seconds, 1)) s"
    }

    // MARK: - Databases

    /// `dbN:keys=…,expires=…,avg_ttl=…` lines in database order; malformed lines are skipped (Show all still has them).
    static func databases(_ section: InfoSection?) -> [InfoDatabase] {
        guard let section else { return [] }
        var databases: [InfoDatabase] = []
        for field in section.fields {
            // The round trip rejects "db01" and "db+1", which `Int` alone would accept.
            let digits = field.name.dropFirst(2)
            guard field.name.hasPrefix("db"), let index = Int(digits), index >= 0, String(index) == digits else { continue }
            var numbers: [Substring: Int] = [:]
            for pair in field.value.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let number = Int(parts[1]) { numbers[parts[0]] = number }
            }
            guard let keys = numbers["keys"], keys >= 0, !databases.contains(where: { $0.index == index }) else { continue }
            databases.append(InfoDatabase(index: index, keys: keys, expires: max(numbers["expires"] ?? 0, 0), averageTTL: max(numbers["avg_ttl"] ?? 0, 0)))
        }
        return databases.sorted { $0.index < $1.index }
    }

    // MARK: - Health

    /// A primary: "No replicas", "2 replicas in sync" or "2 replicas, 1 in sync" (`slaveN:…,state=online`).
    /// A replica: "Replica of 10.0.0.5:6379, link up".
    static func replication(_ report: InfoReport) -> String {
        guard let role = report["role"]?.lowercased() else { return unavailable }
        if role == "slave" || role == "replica" {
            let primary = [report["master_host"], report["master_port"]].compactMap { $0 }.joined(separator: ":")
            let link = report["master_link_status"].map { ", link \($0)" } ?? ""
            return primary.isEmpty ? "Replica\(link)" : "Replica of \(primary)\(link)"
        }
        let section = report.section("Replication")?.fields ?? []
        let replicas = section.filter { $0.name.hasPrefix("slave") && Int($0.name.dropFirst(5)) != nil }
        let count = report["connected_slaves"].flatMap(Int.init) ?? replicas.count
        guard count > 0 else { return "No replicas" }
        let noun = count == 1 ? "replica" : "replicas"
        // Without per-replica lines (Dragonfly), there is no state to report beyond the count.
        guard !replicas.isEmpty else { return "\(count) \(noun)" }
        let online = replicas.filter { $0.value.split(separator: ",").contains("state=online") }.count
        return online == count ? "\(count) \(noun) in sync" : "\(count) \(noun), \(online) in sync"
    }

    /// `rdb_last_save_time` relative to `now` ("6 minutes ago"); a failed last background save says so first.
    static func lastSave(_ report: InfoReport, now: Date) -> String {
        guard let time = report["rdb_last_save_time"].flatMap(Int64.init) else { return unavailable }
        guard time > 0 else { return "Never" }
        let ago = relative(seconds: Int64(now.timeIntervalSince1970) - time)
        return report["rdb_last_bgsave_status"]?.lowercased() == "err" ? "Failed · \(ago)" : ago
    }

    /// "just now", "1 minute ago", "6 hours ago", "3 days ago". A save "in the future" (clock skew) is just now.
    static func relative(seconds: Int64) -> String {
        guard seconds >= 60 else { return "just now" }
        let (value, unit) = largestUnit(seconds: Int(clamping: seconds))
        return "\(KeyIndexFooter.grouped(value)) \(value == 1 ? unit : unit + "s") ago"
    }

    /// `keyspace_hits / (hits + misses)` with one decimal ("97.8%"); "No reads yet" before any key lookup.
    static func hitRatio(_ report: InfoReport) -> String {
        guard let hits = report["keyspace_hits"].flatMap(Double.init), let misses = report["keyspace_misses"].flatMap(Double.init), hits >= 0, misses >= 0,
            (hits + misses).isFinite
        else {
            return unavailable
        }
        guard hits + misses > 0 else { return "No reads yet" }
        return String(format: "%.1f%%", hits / (hits + misses) * 100)
    }
}

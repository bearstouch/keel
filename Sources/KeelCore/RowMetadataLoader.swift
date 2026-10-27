import Foundation
import KeelRESP

/// What one visible key still needs (`KeyIndex.metadataWork`).
public struct RowMetadataWork: Sendable, Equatable {
    public var index: Int
    /// The key's original bytes, as the commands must use them (FR-KB10).
    public var key: Data
    public var type: Bool
    public var ttl: Bool
    public var size: Bool

    public init(index: Int, key: Data, type: Bool, ttl: Bool, size: Bool) {
        self.index = index; self.key = key; self.type = type; self.ttl = ttl; self.size = size
    }
}

/// What came back for one key; nil fields were not asked or not answered.
public struct RowMetadataResult: Sendable, Equatable {
    public var index: Int
    public var type: KeyType?
    public var expiry: RowExpiry?
    public var size: KeySize?

    public init(index: Int, type: KeyType? = nil, expiry: RowExpiry? = nil, size: KeySize? = nil) {
        self.index = index; self.type = type; self.expiry = expiry; self.size = size
    }
}

/// Fills type, TTL and — only on request — memory size for the rows in view (FR-KB06, FR-KB07, NFR-PF07).
///
/// The list calls `load(_:)` with the keys it shows whenever rows come into view. Each batch pipelines `TYPE` and
/// `PTTL` (only what is still unknown) through `DataCommandService` from the `.browser` origin; batches are at least
/// `interval` apart, and a request that arrives while one waits replaces the rows it will fetch. Nothing is sent when
/// every visible row is known, so an idle list sends nothing: TTLs count down on this Mac from the deadline `PTTL`
/// gave. `MEMORY USAGE key SAMPLES 0` is sent only while `showsSizes` is on, for at most `maximumSizes` keys a batch.
public actor RowMetadataLoader {
    /// At most one batch per tab in this interval (NFR-PF07).
    public static let interval: Duration = .milliseconds(100)
    /// Keys one batch covers: more than a screen of rows, bounded however tall the window.
    public static let maximumRows = 256
    /// `MEMORY USAGE`s per batch (FR-KB07).
    public static let maximumSizes = 100

    public nonisolated let index: KeyIndex
    /// Time on a monotonic clock; deadlines in `RowExpiry` are on it, so the list counts down with the same clock.
    public nonisolated let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public private(set) var showsSizes = false
    /// The rows the newest request wants; an older request still waiting leaves them to it.
    private var wanted: [Int] = []
    /// Bumped by every request, so only the newest one keeps sending.
    private var ticket = 0
    private var inFlight = false
    /// No batch may start before this time.
    private var nextBatch: Duration?

    public init(
        index: KeyIndex, now: @escaping @Sendable () -> Duration = RowMetadataLoader.monotonicClock(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.suspendingSleep(for: $0) }
    ) {
        self.index = index; self.now = now; self.sleep = sleep
    }

    /// Time since the clock was made, on `ContinuousClock` (it keeps counting while the Mac sleeps, as TTLs do).
    public static func monotonicClock() -> @Sendable () -> Duration {
        let origin = ContinuousClock.now
        return { ContinuousClock.now - origin }
    }

    /// `now()` in whole milliseconds, the unit of `RowExpiry` deadlines.
    public nonisolated func nowMilliseconds() -> Int64 { Self.milliseconds(now()) }

    /// ⋯ → Show sizes. Turning it off sends nothing; sizes already fetched are kept for when it is turned on again.
    public func setShowsSizes(_ on: Bool) { showsSizes = on }

    /// Fetches what the visible `keys` still need, waiting out the interval since the last batch first. Returns the
    /// indices whose metadata changed, for the list to redraw; an empty result when a newer request took over, nothing
    /// was missing, or a command failed (the rows are asked again when they next come into view, never in a loop).
    @discardableResult
    public func load(_ keys: [Int]) async -> [Int] {
        ticket += 1
        let mine = ticket
        wanted = Array(keys.prefix(Self.maximumRows))
        var changed: [Int] = []
        while mine == ticket {
            let (generation, context, work) = await index.metadataWork(for: wanted, sizes: showsSizes, sizeLimit: Self.maximumSizes)
            guard mine == ticket, !work.isEmpty else { break }
            // Wait out the interval (or the batch in flight), then look again: the rows in view may have changed.
            let wait = inFlight ? Self.interval : (nextBatch.map { $0 - now() } ?? .zero)
            if wait > .zero {
                do { try await sleep(wait) } catch { break }
                continue
            }
            inFlight = true
            nextBatch = now() + Self.interval
            let (results, failed) = await fetch(work, context: context)
            inFlight = false
            changed += await index.applyMetadata(results, generation: generation)
            // A failure would fail again at once; stop and let the next scroll or refresh retry.
            if failed { break }
        }
        return changed
    }

    /// One pipelined batch: every command is sent at once on the browser connection and the replies are matched up.
    private func fetch(_ work: [RowMetadataWork], context: DataContext) async -> (results: [RowMetadataResult], failed: Bool) {
        enum Ask { case type, ttl, size }
        let sentAt = nowMilliseconds()
        let service = index.service
        return await withTaskGroup(of: (Int, Ask, Result<RESPValue, DataCommandError>).self) { group in
            for (offset, item) in work.enumerated() {
                let asks: [(Ask, DataOperation)] = [
                    item.type ? (.type, .type(key: item.key)) : nil, item.ttl ? (.ttl, .pttl(key: item.key)) : nil,
                    item.size ? (.size, .memoryUsage(key: item.key)) : nil
                ].compactMap { $0 }
                for (ask, operation) in asks {
                    group.addTask {
                        do throws(DataCommandError) {
                            return (offset, ask, .success(try await service.execute(.operation(operation), origin: .browser, context: context).reply))
                        } catch { return (offset, ask, .failure(error)) }
                    }
                }
            }
            var results = work.map { RowMetadataResult(index: $0.index) }
            var failed = false
            for await (offset, ask, reply) in group {
                guard case .success(let value) = reply else { failed = true; continue }
                switch ask {
                case .type:
                    switch value {
                    // `none`: the key is gone since SCAN.
                    case .simpleString(let name), .bulkString(let name):
                        if let type = KeyType(typeName: name) { results[offset].type = type } else { results[offset].expiry = .gone }
                    default: failed = true
                    }
                // Replies land in any order: a key another reply already found gone stays gone.
                case .ttl where results[offset].expiry == .gone: continue
                case .ttl:
                    switch value {
                    case .integer(-2): results[offset].expiry = .gone
                    case .integer(let ms) where ms < 0: results[offset].expiry = .persistent
                    // Counted from when the batch was sent, so the countdown never reads longer than the server's TTL.
                    case .integer(let ms): results[offset].expiry = .expires(atMilliseconds: sentAt + ms)
                    default: failed = true
                    }
                case .size:
                    switch value {
                    case .integer(let bytes): results[offset].size = .bytes(bytes)
                    // Null: the key is gone. An error (NOPERM, no MEMORY on this server) won't change on retry.
                    case .null, .nullBulkString: results[offset].size = .unavailable; results[offset].expiry = .gone
                    default: results[offset].size = .unavailable
                    }
                }
            }
            return (results, failed)
        }
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

/// Short and spoken TTLs for key rows (FR-KB06): "45s", "1m 30s", "2h 5m", "3d"; "expired" once the deadline passed.
public enum TTLFormatter {
    /// The row's short form: the largest unit and the next one when it isn't zero, days alone. Remaining time is
    /// rounded up to whole seconds, so `EXPIRE 90` reads "1m 30s" rather than "1m 29s" as the reply arrives.
    public static func short(milliseconds: Int64) -> String {
        guard let parts = parts(milliseconds) else { return "expired" }
        if parts.days > 0 { return "\(parts.days)d" }
        let units = [(parts.hours, "h"), (parts.minutes, "m"), (parts.seconds, "s")].drop { $0.0 == 0 }
        guard let first = units.first else { return "0s" }
        let second = units.dropFirst().first.flatMap { $0.0 == 0 ? nil : $0 }
        return "\(first.0)\(first.1)" + (second.map { " \($0.0)\($0.1)" } ?? "")
    }

    /// The full value for VoiceOver: "3 days 4 hours 12 minutes 5 seconds", "expired".
    public static func spoken(milliseconds: Int64) -> String {
        guard let parts = parts(milliseconds) else { return "expired" }
        let words = [(parts.days, "day"), (parts.hours, "hour"), (parts.minutes, "minute"), (parts.seconds, "second")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.joined(separator: " ")
    }

    private static func parts(_ milliseconds: Int64) -> (days: Int64, hours: Int64, minutes: Int64, seconds: Int64)? {
        guard milliseconds > 0 else { return nil }
        let total = (milliseconds + 999) / 1_000
        return (total / 86_400, total % 86_400 / 3_600, total % 3_600 / 60, total % 60)
    }
}

/// Memory sizes for rows: "512 B", "4.1 KB", "1.2 MB" (binary units, one decimal under 10, fixed across locales).
public enum KeySizeFormatter {
    public static func short(bytes: Int64) -> String {
        guard bytes >= 1_024 else { return "\(max(bytes, 0)) B" }
        var value = Double(bytes) / 1_024, unit = "KB"
        for larger in ["MB", "GB"] where value >= 1_024 { value /= 1_024; unit = larger }
        return value < 10 ? String(format: "%.1f %@", value, unit) : "\(Int(value)) \(unit)"
    }
}

import Foundation
import KeelRESP

/// Bulk delete by pattern (FR-SF05, FR-SF06): `SCAN MATCH <pattern> COUNT 1000 [TYPE t]` and `UNLINK` in batches of up
/// to 1,000 keys on the job's own `job` connection, so the browser's connection stays free (AC2). Every command goes
/// through the data path with origin `.bulk`; the deletes carry the typed confirmation's yes for the pattern.
///
/// Cancel is a flag, not task cancellation: cancelling the task would drop an in-flight `UNLINK`'s reply and make its
/// outcome unknown, while the flag lets that batch finish and stops before the next (02 Architecture → Concurrency).
public actor BulkDeleteJob {
    private static let log = KeelLog(.jobs)
    public static let scanCount = 1_000
    public static let batchSize = 1_000
    /// Preview matches shows at most this many names.
    public static let previewLimit = 100
    /// FR-SF06: 10 batches per second unless the user picks another rate (1–100) or unthrottled.
    public static let defaultThrottle = 10
    public static let throttleRange = 1...100
    /// The sample behind the estimate and the preview reads at most this many SCAN pages, however sparse the pattern.
    public static let sampleScans = 20
    /// SCAN starts at cursor 0 and is done when the reply's cursor is 0 again.
    private static let startCursor = Data("0".utf8)

    /// Same stops as a multi-key delete: refused or lost (`.command`), a server error (`.server`), Cancel (`.cancelled`).
    public typealias Failure = MultiKeyDelete.Failure

    /// Monotonic time and sleeping, injected so the throttle is tested without waiting.
    public struct Clock: Sendable {
        public var now: @Sendable () -> Duration
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) { self.now = now; self.sleep = sleep }

        public static var continuous: Clock {
            let clock = ContinuousClock(), start = clock.now
            return Clock(now: { clock.now - start }, sleep: { try await clock.sleep(for: $0) })
        }
    }

    /// What the progress line shows after each batch.
    public struct Progress: Sendable, Equatable {
        /// SCAN pages read (each examines about `scanCount` keys).
        public var scans = 0
        /// Keys SCAN returned that match the pattern (a key SCAN returns twice counts twice).
        public var matched = 0
        /// What the `UNLINK` replies counted.
        public var deleted = 0
        public var elapsed: Duration = .zero

        public init(scans: Int = 0, matched: Int = 0, deleted: Int = 0, elapsed: Duration = .zero) {
            self.scans = scans; self.matched = matched; self.deleted = deleted; self.elapsed = elapsed
        }

        /// Keys deleted per second so far; nil before any time has passed.
        public var rate: Double? {
            let seconds = Self.seconds(elapsed)
            return seconds > 0 ? Double(deleted) / seconds : nil
        }

        /// "1,221,000 deleted · about a minute left"; without an estimate (or once past it) just the count.
        public func line(estimate: Int?) -> String {
            let done = "\(KeyIndexFooter.grouped(deleted)) deleted"
            guard let estimate, let rate, rate > 0, estimate > deleted else { return done }
            return "\(done) · \(BulkDeleteJob.remaining(seconds: Double(estimate - deleted) / rate))"
        }

        /// Share of the estimate done, for the bar; nil (indeterminate) without one.
        public func fraction(estimate: Int?) -> Double? {
            guard let estimate, estimate > 0 else { return nil }
            return min(Double(deleted) / Double(estimate), 1)
        }

        static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }

    public struct Report: Sendable, Equatable {
        public var pattern: Data
        public var progress: Progress
        public var failure: Failure?

        public var isComplete: Bool { failure == nil }
        public var deleted: Int { progress.deleted }

        /// SCAN only guarantees keys that existed for the whole run (AC4).
        public static let caveat = "Keys created or renamed while it ran may remain."

        /// "Deleted 1,221,000 keys matching tmp:import:*." plus why it stopped, then the SCAN caveat.
        public var summary: String {
            let count = KeyIndexFooter.grouped(deleted), keys = deleted == 1 ? "key" : "keys"
            let done = "Deleted \(count) \(keys) matching \(KeyDisplay.name(pattern))"
            let stop: String
            switch failure {
            case nil: stop = "."
            case .cancelled?: stop = "; the job was cancelled."
            case .server(let message)?: stop = ". The server refused the next batch: \(message)"
            case .command(.command(.outcomeUnknown))?, .command(.command(.timeout))?:
                stop = ". The connection was lost during a batch, so whether its keys were deleted is unknown."
            case .command(let error)?: stop = ". It stopped: \(KeyIndex.describe(error, command: "the bulk delete"))"
            }
            return done + stop + " " + Self.caveat
        }

        /// "Scanned 2,100 pages · matched 1,221,000 · 12,000 keys/s".
        public var details: String {
            var parts = ["Scanned \(KeyIndexFooter.grouped(progress.scans)) \(progress.scans == 1 ? "page" : "pages")", "matched \(KeyIndexFooter.grouped(progress.matched))"]
            if let rate = progress.rate { parts.append("\(KeyIndexFooter.grouped(Int(rate.rounded()))) keys/s") }
            return parts.joined(separator: " · ")
        }
    }

    /// The first matches and how much of the database they come from (the confirmation's estimate and Preview matches).
    public struct Sample: Sendable, Equatable {
        /// Up to `previewLimit` distinct matching keys, in SCAN order.
        public var keys: [Data]
        /// Distinct matching keys seen (keeps counting past `previewLimit`).
        public var matched: Int
        public var scans: Int
        /// The cursor came back to 0: `matched` is every key that matched while the sample ran.
        public var complete: Bool
        /// `DBSIZE` when read.
        public var databaseSize: Int?
        /// Why the sample stopped early (the confirmation then shows no count).
        public var failure: Failure?

        /// The confirmation's count: exact when the whole database was sampled, else `matched` scaled to the database
        /// (each page examines about `scanCount` keys); nil when the size is unknown.
        public var estimate: Int? {
            if complete { return matched }
            guard let size = databaseSize, scans > 0 else { return nil }
            let examined = min(scans * BulkDeleteJob.scanCount, size)
            return examined > 0 ? Int((Double(matched) / Double(examined) * Double(size)).rounded()) : nil
        }
    }

    public nonisolated let id = UUID()
    public nonisolated let pattern: Data
    public nonisolated let type: KeyTypeFilter?
    /// Batches per second; nil runs unthrottled. Set before `run` (the confirmation sheet's choice).
    public private(set) var throttle: Int?
    public nonisolated let service: DataCommandService
    let profile: SafetyProfile
    let database: Int
    let clock: Clock
    private let cancelFlag = CancelFlag()
    private var running = false
    /// When the last `UNLINK` was sent, for the throttle.
    private var lastBatch: Duration?

    /// Throws `INVALID_PARAMS` for a pattern or type the job refuses (`refusal`); nothing is sent then.
    public init(pattern: Data, type: KeyTypeFilter? = nil, throttle: Int? = defaultThrottle, service: DataCommandService, profile: SafetyProfile, database: Int, clock: Clock = .continuous)
        throws(DataCommandError)
    {
        if let refusal = Self.refusal(pattern: pattern, type: type) { throw .invalidRequest(refusal) }
        self.pattern = pattern; self.type = type; self.service = service; self.profile = profile; self.database = database; self.clock = clock
        self.throttle = Self.clamped(throttle)
    }

    /// FR-SF06: 1–100 batches per second, or nil for unthrottled.
    public func setThrottle(_ throttle: Int?) { self.throttle = Self.clamped(throttle) }

    static func clamped(_ throttle: Int?) -> Int? { throttle.map { min(max($0, throttleRange.lowerBound), throttleRange.upperBound) } }

    /// Why the job can't run with this pattern and type; nil when it can. `*` (or `**`) is every key: that is FLUSHDB.
    public static func refusal(pattern: Data, type: KeyTypeFilter?) -> String? {
        if pattern.isEmpty { return "Enter a pattern to delete the keys that match it." }
        if GlobPattern.matchesEverything(pattern) { return "The pattern * matches every key; use FLUSHDB to empty the database." }
        // SCAN can't select module types; checking each key's TYPE first is not offered for deletes.
        if type == .other { return "Bulk delete can filter by the six core types only." }
        return nil
    }

    /// The yes the typed confirmation gives: `UNLINK` batches whose keys all match `pattern`, in this database.
    public static func confirmation(for pattern: Data, database: Int) -> CommandConfirmation {
        CommandConfirmation(scope: .pattern(pattern), database: database)
    }

    /// The typed confirmation (type the pattern), its sentence carrying the sample's count when there is one:
    /// "About 2.1 million keys match tmp:import:* in api-staging db0. This can't be undone."
    public static func request(for pattern: Data, estimate: Int?, exact: Bool = false, profile: SafetyProfile, database: Int) -> TypedConfirmation {
        var request = TypedConfirmation(operation: .deletePattern(pattern), profile: profile, database: database)
        if let estimate {
            let count = exact ? KeyIndexFooter.grouped(estimate) : about(estimate)
            let verb = estimate == 1 ? "key matches" : "keys match"
            request.message = "\(count) \(verb) \(KeyDisplay.name(pattern)) in \(profile.name) db\(database). This can't be undone."
        }
        return request
    }

    public var context: DataContext { DataContext(profile: profile, database: database, jobID: id) }

    /// Stops the run after the batch in flight; a job not started yet never sends a delete. Callable from anywhere
    /// without waiting for the actor, which is busy awaiting that batch.
    public nonisolated func cancel() { cancelFlag.set() }
    public nonisolated var isCancelled: Bool { cancelFlag.isSet }

    /// Reads up to `sampleScans` SCAN pages (stopping once `previewLimit` keys matched) and `DBSIZE`, on the job connection.
    /// It stops at Cancel or once the run started, so it never sends after the run (or a dismissal) closed the connection.
    public func sample() async -> Sample {
        let sample = await readSample()
        // A Cancel (the sheet closed) may have closed the connection while a page was in flight; a command sent after
        // that opened it again, with nobody left to close it.
        if isCancelled { await close() }
        return sample
    }

    private func readSample() async -> Sample {
        var sample = Sample(keys: [], matched: 0, scans: 0, complete: false, databaseSize: nil, failure: nil)
        var seen = Set<Data>(), cursor = Self.startCursor
        while sample.scans < Self.sampleScans, sample.keys.count < Self.previewLimit, !isCancelled, !running {
            switch await scan(cursor) {
            // A failed page ends the sample without `DBSIZE`: the sentence then shows no count.
            case .failure(let failure): sample.failure = failure; return sample
            case .success(let page):
                sample.scans += 1; cursor = page.cursor
                for key in page.keys where GlobPattern.matches(pattern, key) && seen.insert(key).inserted {
                    sample.matched += 1
                    if sample.keys.count < Self.previewLimit { sample.keys.append(key) }
                }
            }
            if cursor == Self.startCursor { sample.complete = true; break }
        }
        // The size is only for the estimate: a failure to read it leaves the sentence without a number.
        guard !isCancelled, !running else { return sample }
        if case .integer(let size)? = try? await service.execute(.operation(.databaseSize), origin: .bulk, context: context).reply { sample.databaseSize = Int(size) }
        return sample
    }

    /// Closes the job connection (the sheet closed without running, or after the sample).
    public func close() async { await service.session.close(.job(id)) }

    /// Scans the whole database once and deletes what matches, `batchSize` keys per `UNLINK`, at most `throttle`
    /// batches per second. Stops at Cancel or at the first batch that fails; a lost reply is never re-sent
    /// (`OUTCOME_UNKNOWN`). `confirmation` must be `confirmation(for:database:)` of this pattern. Runs once; the job
    /// connection is closed when it ends.
    public func run(confirmation: CommandConfirmation, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Report {
        var report = Report(pattern: pattern, progress: Progress(), failure: nil)
        // A second run would rescan and delete again under a confirmation given once.
        guard !running else { report.failure = .command(.invalidRequest("This bulk delete has already run.")); return report }
        running = true
        let started = clock.now()
        var context = self.context
        context.confirmation = confirmation
        var cursor = Self.startCursor, pending: [Data] = [], pendingSet = Set<Data>()
        func publish() { report.progress.elapsed = clock.now() - started; progress(report.progress) }

        scanning: while true {
            if isCancelled { report.failure = .cancelled; break }
            switch await scan(cursor) {
            case .failure(let failure): report.failure = failure; break scanning
            case .success(let page):
                report.progress.scans += 1; cursor = page.cursor
                // SCAN already matched; checked again so a single-key batch (a plain write the policy doesn't tie to
                // the pattern) can never name another key. A key repeated within the pending batch is sent once.
                for key in page.keys where GlobPattern.matches(pattern, key) && pendingSet.insert(key).inserted {
                    pending.append(key); report.progress.matched += 1
                }
            }
            let finished = cursor == Self.startCursor
            // Full batches go now; the remainder waits for more keys unless the scan is over. Bounded: at most one
            // page beyond a batch is ever held.
            while pending.count >= Self.batchSize || (finished && !pending.isEmpty) {
                let batch = Array(pending.prefix(Self.batchSize))
                pending.removeFirst(batch.count); pendingSet.subtract(batch)
                switch await unlink(batch, context: context) {
                case .success(let deleted): report.progress.deleted += deleted; publish()
                // Stop at the first failed batch; a lost reply is reported, never re-sent.
                case .failure(let failure): report.failure = failure; break scanning
                }
            }
            publish()
            if finished { break }
        }
        report.progress.elapsed = clock.now() - started
        // Counts and the stop code only: never the pattern or a key (NFR-PV02).
        let stop: LogField = .code(report.failure.map(\.code) ?? "COMPLETED")
        Self.log.log(.info, "bulk_delete.finished", .count("scans", report.progress.scans), .count("matched", report.progress.matched), .count("deleted", report.deleted), stop)
        await close()
        return report
    }

    /// Sends one `UNLINK` after waiting out the throttle; the count it deleted, or why the run stops.
    private func unlink(_ batch: [Data], context: DataContext) async -> Result<Int, Failure> {
        if let throttle, let lastBatch {
            // Batches start at least 1/throttle s apart, so any one-second window holds at most `throttle` of them.
            let due = lastBatch + .seconds(1) / throttle, now = clock.now()
            if due > now {
                // The sleep throws only when the task is cancelled: treat it as Cancel, before anything is sent.
                do { try await clock.sleep(due - now) } catch { return .failure(.cancelled) }
            }
        }
        // Checked after the wait too, so Cancel during a throttle pause sends nothing more.
        if isCancelled { return .failure(.cancelled) }
        lastBatch = clock.now()
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await service.execute(.operation(.delete(keys: batch)), origin: .bulk, context: context).reply
        } catch {
            return .failure(.command(error))
        }
        switch reply {
        case .integer(let count): return .success(Int(count))
        // An error reply (an ACL refusal) deleted nothing in this batch; the message is bounded for the report.
        case .error(let text), .blobError(let text): return .failure(.server(String(decoding: text.prefix(512), as: UTF8.self)))
        default:
            // Not an UNLINK reply: what happened to this batch is unknown, so nothing more is sent.
            return .failure(.command(.command(.outcomeUnknown)))
        }
    }

    /// One SCAN page under the job's pattern and type.
    private func scan(_ cursor: Data) async -> Result<KeyIndex.Page, Failure> {
        let operation = DataOperation.scan(cursor: cursor, match: pattern, count: Self.scanCount, type: type.map { Data($0.rawValue.utf8) })
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await service.execute(.operation(operation), origin: .bulk, context: context).reply
        } catch {
            return .failure(.command(error))
        }
        // An error reply or a malformed page stops the job as the server's error.
        return KeyIndex.parse(reply).mapError { .server($0.message) }
    }

    /// 2,140,000 → "About 2.1 million", 12,345 → "About 12,000", 57 → "About 57".
    static func about(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = (Double(count) / 1e6 * 10).rounded() / 10
            let text = millions == millions.rounded() ? String(Int(millions)) : String(format: "%.1f", millions)
            return "About \(text) million"
        }
        if count >= 10_000 { return "About \(KeyIndexFooter.grouped((count + 500) / 1_000 * 1_000))" }
        return "About \(KeyIndexFooter.grouped(count))"
    }

    /// "about a minute left", "about 12 minutes left", "less than a minute left".
    static func remaining(seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 45 { return "less than a minute left" }
        if minutes <= 1 { return "about a minute left" }
        if minutes < 90 { return "about \(minutes) minutes left" }
        let hours = Int((seconds / 3600).rounded())
        return hours <= 1 ? "about an hour left" : "about \(hours) hours left"
    }
}

/// Set once by Cancel, read by the run between steps.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Lets the job's steps return `Result<_, Failure>` without a wrapper type.
extension MultiKeyDelete.Failure: Error {}

extension GlobPattern {
    /// Only `*`s: a pattern every key matches (FR-SF05 refuses it).
    public static func matchesEverything(_ pattern: Data) -> Bool { !pattern.isEmpty && pattern.allSatisfy { $0 == UInt8(ascii: "*") } }
}

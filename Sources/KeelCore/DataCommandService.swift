import Foundation
import KeelRESP

/// A typed edit or read an editor, the browser or a job asks for. Editors never build command strings: each
/// operation compiles to one command that the safety policy classifies like any other (02 Architecture).
public enum DataOperation: Sendable, Equatable {
    // Browser and metadata reads
    case scan(cursor: Data, match: Data?, count: Int, type: Data?)
    case type(key: Data)
    case pttl(key: Data)
    /// `MEMORY USAGE key SAMPLES 0`: sent only when the user asks for sizes (FR-KB07).
    case memoryUsage(key: Data)
    case get(key: Data)
    /// `GETRANGE key start end` (inclusive offsets): a large string's first page (FR-ED01).
    case getRange(key: Data, start: Int, end: Int)
    /// `DBSIZE` for the context's database: the footer's total (FR-KB09).
    case databaseSize
    /// `INFO section`; the database switcher asks for `keyspace` (FR-KB08). Nil sends a bare `INFO`, the server's default
    /// sections, which Info mode shows (FR-SI01).
    case info(section: Data?)
    /// `OBJECT ENCODING key` for the editor's Details (FR-ED13).
    case objectEncoding(key: Data)
    /// The editor's length for the metadata line (`STRLEN`, `HLEN`, `LLEN`, `SCARD`, `ZCARD`, `XLEN`).
    case length(key: Data, command: LengthCommand)
    /// `HGETALL key`: a hash of up to 1,000 fields at once (FR-ED02).
    case hashGetAll(key: Data)
    /// `HSCAN key cursor COUNT n`: one page of a larger hash.
    case hashScan(key: Data, cursor: Data, count: Int)
    /// `HGET key field`: a save's guard read, and the overwrite check for a field not loaded yet.
    case hashGet(key: Data, field: Data)
    /// `LRANGE key start stop` (inclusive): a page of a list, and a list save's guard read (FR-ED03).
    case listRange(key: Data, start: Int, stop: Int)
    /// `SMEMBERS key`: a set of up to 1,000 members at once (FR-ED04).
    case setMembers(key: Data)
    /// `SSCAN key cursor COUNT n`: one page of a larger set.
    case setScan(key: Data, cursor: Data, count: Int)
    /// `SISMEMBER key member`: whether a removed member is gone after a save.
    case setIsMember(key: Data, member: Data)
    /// One page of a sorted set by score, `WITHSCORES` (FR-ED05): `ZRANGE … BYSCORE [REV] … LIMIT` where the server
    /// supports it (`byScore`, probed), else `ZRANGEBYSCORE` / `ZREVRANGEBYSCORE`. `min` / `max` are Redis's spelling.
    case sortedSetRange(key: Data, min: Data, max: Data, offset: Int, count: Int, reverse: Bool, byScore: Bool)
    /// `ZSCAN key cursor [MATCH pattern] COUNT n`: the sorted set editor's pattern search.
    case sortedSetScan(key: Data, cursor: Data, match: Data?, count: Int)
    /// `ZSCORE key member`: a score change's guard read, and its read-back after a save.
    case sortedSetScore(key: Data, member: Data)
    /// `XRANGE key from to COUNT n`, or `XREVRANGE` with `reverse` (`from` is then the higher bound): a page of a stream
    /// (FR-ED06). Bounds are Redis's spelling (`-`, `+`, `1700000000000-5`, `(1700000000000-5`).
    case streamRange(key: Data, from: Data, to: Data, count: Int, reverse: Bool)
    /// `XINFO STREAM key`: the stream summary in Details.
    case streamInfo(key: Data)
    /// `PEXPIRETIME key` (7.0+, probed): the absolute expiry as Unix milliseconds (FR-ED11).
    case expireTime(key: Data)
    /// `EXISTS key`: the new-key sheet's guard read (FR-ED14), 0 while the name is free.
    case exists(key: Data)
    // Writes
    case stringSet(key: Data, value: Data, keepTTL: Bool)
    /// `SET key value NX [PX ms]`: a new string that never replaces an existing key (FR-ED14).
    case stringCreate(key: Data, value: Data, milliseconds: Int64?)
    case hashSetField(key: Data, field: Data, value: Data)
    case hashDeleteFields(key: Data, fields: [Data])
    case listPush(key: Data, values: [Data], atHead: Bool)
    case listSet(key: Data, index: Int, value: Data)
    case listRemove(key: Data, count: Int, value: Data)
    /// `LPOP` / `RPOP key`: one item from the head or the tail.
    case listPop(key: Data, atHead: Bool)
    /// `LINSERT key BEFORE|AFTER pivot value`: the list editor's pivot is a unique sentinel, so the place is exact.
    case listInsert(key: Data, before: Bool, pivot: Data, value: Data)
    case setAdd(key: Data, members: [Data])
    case setRemove(key: Data, members: [Data])
    /// `ZADD key [XX] score member …`; `existingOnly` (XX) changes scores without adding members.
    case sortedSetAdd(key: Data, members: [ScoredMember], existingOnly: Bool = false)
    /// `ZINCRBY key increment member`.
    case sortedSetIncrement(key: Data, increment: Double, member: Data)
    case sortedSetRemove(key: Data, members: [Data])
    case streamAdd(key: Data, id: Data, fields: [FieldValue])
    case streamDelete(key: Data, ids: [Data])
    case rename(key: Data, newKey: Data, overwrite: Bool)
    case expire(key: Data, milliseconds: Int64)
    /// `PEXPIREAT key unix-ms`: an absolute expiry (FR-ED11).
    case expireAt(key: Data, unixMilliseconds: Int64)
    case persist(key: Data)
    /// `UNLINK`; more than one key is destructive and needs a confirmation (FR-SF03, FR-SF04).
    case delete(keys: [Data])
    case flushDatabase(async: Bool)
    case flushAll(async: Bool)

    public struct ScoredMember: Sendable, Equatable {
        public var score: Double
        public var member: Data
        public init(score: Double, member: Data) { self.score = score; self.member = member }
    }

    public struct FieldValue: Sendable, Equatable {
        public var field: Data
        public var value: Data
        public init(field: Data, value: Data) { self.field = field; self.value = value }
    }

    /// The command this operation sends; bytes pass through unchanged.
    public var arguments: [Data] {
        switch self {
        case .scan(let cursor, let match, let count, let type):
            var args = [d("SCAN"), cursor]
            if let match { args += [d("MATCH"), match] }
            args += [d("COUNT"), d(String(count))]
            if let type { args += [d("TYPE"), type] }
            return args
        case .type(let key): return [d("TYPE"), key]
        case .pttl(let key): return [d("PTTL"), key]
        case .memoryUsage(let key): return [d("MEMORY"), d("USAGE"), key, d("SAMPLES"), d("0")]
        case .get(let key): return [d("GET"), key]
        case .getRange(let key, let start, let end): return [d("GETRANGE"), key, d(String(start)), d(String(end))]
        case .databaseSize: return [d("DBSIZE")]
        case .info(let section): return section.map { [d("INFO"), $0] } ?? [d("INFO")]
        case .objectEncoding(let key): return [d("OBJECT"), d("ENCODING"), key]
        case .length(let key, let command): return [d(command.rawValue), key]
        case .hashGetAll(let key): return [d("HGETALL"), key]
        case .hashScan(let key, let cursor, let count): return [d("HSCAN"), key, cursor, d("COUNT"), d(String(count))]
        case .hashGet(let key, let field): return [d("HGET"), key, field]
        case .listRange(let key, let start, let stop): return [d("LRANGE"), key, d(String(start)), d(String(stop))]
        case .setMembers(let key): return [d("SMEMBERS"), key]
        case .setScan(let key, let cursor, let count): return [d("SSCAN"), key, cursor, d("COUNT"), d(String(count))]
        case .setIsMember(let key, let member): return [d("SISMEMBER"), key, member]
        case .sortedSetRange(let key, let min, let max, let offset, let count, let reverse, let byScore):
            return CapabilitySet.zrangeByScore(byScore: byScore, key: key, min: min, max: max, offset: offset, count: count, reverse: reverse)
        case .sortedSetScan(let key, let cursor, let match, let count):
            return [d("ZSCAN"), key, cursor] + (match.map { [d("MATCH"), $0] } ?? []) + [d("COUNT"), d(String(count))]
        case .sortedSetScore(let key, let member): return [d("ZSCORE"), key, member]
        case .streamRange(let key, let from, let to, let count, let reverse): return [d(reverse ? "XREVRANGE" : "XRANGE"), key, from, to, d("COUNT"), d(String(count))]
        case .streamInfo(let key): return [d("XINFO"), d("STREAM"), key]
        case .expireTime(let key): return [d("PEXPIRETIME"), key]
        case .exists(let key): return [d("EXISTS"), key]
        case .stringSet(let key, let value, let keepTTL): return [d("SET"), key, value] + (keepTTL ? [d("KEEPTTL")] : [])
        case .stringCreate(let key, let value, let milliseconds): return [d("SET"), key, value, d("NX")] + (milliseconds.map { [d("PX"), d(String($0))] } ?? [])
        case .hashSetField(let key, let field, let value): return [d("HSET"), key, field, value]
        case .hashDeleteFields(let key, let fields): return [d("HDEL"), key] + fields
        case .listPush(let key, let values, let atHead): return [d(atHead ? "LPUSH" : "RPUSH"), key] + values
        case .listSet(let key, let index, let value): return [d("LSET"), key, d(String(index)), value]
        case .listRemove(let key, let count, let value): return [d("LREM"), key, d(String(count)), value]
        case .listPop(let key, let atHead): return [d(atHead ? "LPOP" : "RPOP"), key]
        case .listInsert(let key, let before, let pivot, let value): return [d("LINSERT"), key, d(before ? "BEFORE" : "AFTER"), pivot, value]
        case .setAdd(let key, let members): return [d("SADD"), key] + members
        case .setRemove(let key, let members): return [d("SREM"), key] + members
        case .sortedSetAdd(let key, let members, let existingOnly):
            return [d("ZADD"), key] + (existingOnly ? [d("XX")] : []) + members.flatMap { [d(Self.score($0.score)), $0.member] }
        case .sortedSetIncrement(let key, let increment, let member): return [d("ZINCRBY"), key, d(Self.score(increment)), member]
        case .sortedSetRemove(let key, let members): return [d("ZREM"), key] + members
        case .streamAdd(let key, let id, let fields): return [d("XADD"), key, id] + fields.flatMap { [$0.field, $0.value] }
        case .streamDelete(let key, let ids): return [d("XDEL"), key] + ids
        case .rename(let key, let newKey, let overwrite): return [d(overwrite ? "RENAME" : "RENAMENX"), key, newKey]
        case .expire(let key, let milliseconds): return [d("PEXPIRE"), key, d(String(milliseconds))]
        case .expireAt(let key, let unixMilliseconds): return [d("PEXPIREAT"), key, d(String(unixMilliseconds))]
        case .persist(let key): return [d("PERSIST"), key]
        case .delete(let keys): return [d("UNLINK")] + keys
        case .flushDatabase(let async): return [d("FLUSHDB")] + (async ? [d("ASYNC")] : [])
        case .flushAll(let async): return [d("FLUSHALL")] + (async ? [d("ASYNC")] : [])
        }
    }

    /// Redis spells infinities `inf` / `-inf`; finite scores keep Swift's shortest round-trip form.
    static func score(_ value: Double) -> String {
        if value.isInfinite { return value < 0 ? "-inf" : "+inf" }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

private func d(_ text: String) -> Data { Data(text.utf8) }

/// What to run: a typed operation, or raw arguments (console lines after tokenizing).
public enum DataCommand: Sendable, Equatable {
    case operation(DataOperation)
    case raw([Data])

    public var arguments: [Data] {
        switch self {
        case .operation(let operation): return operation.arguments
        case .raw(let arguments): return arguments
        }
    }
}

/// Where a command runs and the confirmation it carries, if any.
public struct DataContext: Sendable, Equatable {
    public var profile: SafetyProfile
    public var database: Int
    /// The console a `.console` command comes from; its connection keeps that console's state.
    public var consoleID: UUID?
    /// The bulk job a `.bulk` command belongs to.
    public var jobID: UUID?
    public var confirmation: CommandConfirmation?

    public init(profile: SafetyProfile, database: Int = 0, consoleID: UUID? = nil, jobID: UUID? = nil, confirmation: CommandConfirmation? = nil) {
        self.profile = profile; self.database = database; self.consoleID = consoleID; self.jobID = jobID; self.confirmation = confirmation
    }
}

/// Why a command didn't run or didn't complete. `code` is the shared error code (`specs/02-architecture.md#errors`).
public enum DataCommandError: Error, Equatable, Sendable {
    /// The safety policy refused it; nothing was sent.
    case refused(SafetyVerdict)
    /// The request itself is malformed (no arguments, a console command without its console); nothing was sent.
    case invalidRequest(String)
    /// The role's connection couldn't be opened; nothing was sent.
    case connection(ConnectionFailure)
    /// The connection failed, timed out or was closed around the command (`OUTCOME_UNKNOWN` for a possible write).
    case command(RedisError)
    /// A guarded save found the key changed since the editor loaded it; nothing was written.
    case conflict

    public var code: String {
        switch self {
        case .refused(let verdict): return verdict.code ?? "BLOCKED_COMMAND"
        case .invalidRequest: return "INVALID_PARAMS"
        case .connection(let failure): return failure.category == .timeout ? "TIMEOUT" : "CONNECTION_FAILED"
        case .command(let error): return error.code
        case .conflict: return "CONFLICT"
        }
    }
}

/// What a guarded save expects to find (03 → Value editors, concurrency): the replies `reads` gave when the editor
/// loaded `key`. The save re-reads them under `WATCH`; any difference is `CONFLICT`.
public struct WatchGuard: Sendable, Equatable {
    public var key: Data
    public var reads: [DataOperation]
    public var expected: [RESPValue]

    public init(key: Data, reads: [DataOperation], expected: [RESPValue]) { self.key = key; self.reads = reads; self.expected = expected }
}

public struct DataCommandResult: Sendable, Equatable {
    /// The server's reply; a server error (`-WRONGTYPE …`) is a value, not a thrown error.
    public var reply: RESPValue
    public var safetyClass: SafetyClass
    public var role: ConnectionRole

    /// The console shows a notice for a command Keel doesn't know (it ran it anyway on a writable profile).
    public var isUnknownCommand: Bool { safetyClass == .unknown }
}

/// What the data path tells its tab about writes (FR-SF07, 02 Architecture → server-enforced read-only).
public enum WriteEvent: Sendable, Equatable {
    /// A command that may change data passed the policy and is being sent.
    case sent
    /// The server refused a write because this user or server can't write (`NOPERM … permissions to run`, `READONLY`).
    case serverRefused
}

/// Server replies that mean writes are refused by the server itself, not by Keel.
public enum ServerReadOnly {
    /// `READONLY You can't write against a read only replica.`, or an ACL refusal of the command itself (Redis 6:
    /// `NOPERM this user has no permissions to run the 'set' command…`; 7+ and Valkey: `NOPERM User u has no permissions
    /// to run the 'set' command`). A key-pattern refusal (`no permissions to access a key`) leaves other keys writable,
    /// so it doesn't count. Nor does an ACL refusal of anything but a plain data write (`-@admin`, `-@dangerous` refuse
    /// `CONFIG SET` or `FLUSHALL` while `SET` still runs): `of` is the refused command's class.
    public static func refusesWrites(_ reply: RESPValue, of safetyClass: SafetyClass = .write) -> Bool {
        let text: Data
        switch reply {
        case .error(let bytes), .blobError(let bytes): text = bytes
        default: return false
        }
        let message = String(decoding: text.prefix(256), as: UTF8.self)
        if message.hasPrefix("READONLY ") { return true }
        return safetyClass == .write && message.hasPrefix("NOPERM ") && message.contains("permissions to run")
    }
}

/// The single entry point for every server command — editors, browser, console and bulk jobs
/// (02 Architecture → One data path). The policy decides before anything is written: a refused command opens no
/// connection and sends no byte.
public actor DataCommandService {
    public let session: ServerSession
    public private(set) var catalog: CommandCatalog
    /// Refusals and failures log their code only (NFR-PV02): never the command, its keys or the reply.
    private static let log = KeelLog(.data)

    /// Roles with a transaction in progress, and the transactions waiting for each. `EXEC` ends every `WATCH` on its
    /// connection, so two saves on the browser connection must not overlap.
    private var transacting: Set<ConnectionRole> = []
    private var waitingTransactions: [ConnectionRole: [CheckedContinuation<Void, Never>]] = [:]

    /// The session's FR-CN12 probes, made on first use (06 → Probes).
    private var probe: CapabilityProbe?
    /// Set when the profile became read-only while the session was open: every later command is evaluated as read-only,
    /// whatever context the caller still holds. One way: turning read-only off takes a new session (Reconnect).
    public private(set) var isReadOnlyLocked = false
    private var writeObserver: (@Sendable (WriteEvent) -> Void)?

    public init(session: ServerSession, catalog: CommandCatalog = .bundled) { self.session = session; self.catalog = catalog }

    /// Whether the server has `capability`, probed once per session on the browser connection (a read, like the session's
    /// other setup probes) and cached. A probe that can't be made answers false, so callers take the fallback that works
    /// on every supported server; it is asked again next time.
    public func supports(_ capability: ServerCapability, context: DataContext) async -> Bool {
        let probe =
            probe
            ?? CapabilityProbe { [session, database = context.database] (arguments: [Data]) async throws(RedisError) -> RESPValue in
                let connection: RedisConnection
                do throws(ConnectionFailure) { connection = try await session.connection(for: .browser(database: database), database: database) } catch { throw .notConnected }
                return try await connection.send(arguments, mayWrite: false)
            }
        self.probe = probe
        return (try? await probe.status(capability))?.isAvailable ?? false
    }

    /// The profile was made read-only while this session is open (FR-SF01): from now on nothing that may write is sent.
    public func lockReadOnly() { isReadOnlyLocked = true }

    /// Tells the tab about writes sent and writes the server refused; one observer, replaced by the next.
    public func observeWrites(_ observer: (@Sendable (WriteEvent) -> Void)?) { writeObserver = observer }

    /// The safety facts a command is evaluated with: the caller's, made read-only by `lockReadOnly()`.
    private func effective(_ profile: SafetyProfile) -> SafetyProfile {
        var profile = profile
        if isReadOnlyLocked { profile.readOnly = true }
        return profile
    }

    /// Connection-state and streaming commands change no data, so they don't count as writes for the notice.
    private static func changesData(_ safetyClass: SafetyClass) -> Bool { safetyClass.mayWrite && ![.session, .streaming].contains(safetyClass) }

    // `execute` and `executeTransaction` wrap their bodies so every throw path, refusals included, logs its code once.
    public func execute(_ command: DataCommand, origin: CommandOrigin, context: DataContext) async throws(DataCommandError) -> DataCommandResult {
        do { return try await run(command, origin: origin, context: context) } catch {
            // A refusal (READ_ONLY, CONFIRMATION_REQUIRED before the typed confirmation) is the policy working, not a
            // failure: logged at info, so it doesn't crowd real errors out of the diagnostics.
            if case .refused = error { Self.log.log(.info, "command.refused", .code(error.code)) } else { Self.log.error("command.failed", .code(error.code)) }
            throw error
        }
    }

    private func run(_ command: DataCommand, origin: CommandOrigin, context: DataContext) async throws(DataCommandError) -> DataCommandResult {
        let arguments = command.arguments
        guard !arguments.isEmpty else { throw .invalidRequest("A command needs at least its name.") }
        let info = catalog.resolve(arguments)
        let verdict = SafetyPolicy.evaluate(
            arguments, command: info, origin: origin, profile: effective(context.profile), database: context.database, confirmation: context.confirmation)
        guard case .allow(let safetyClass) = verdict else { throw .refused(verdict) }
        let role = try Self.role(for: origin, safetyClass, context)
        let writes = Self.changesData(safetyClass)
        if writes { writeObserver?(.sent) }
        // A console's blocking command (`BLPOP k 0`) may wait for good; its Stop closes the connection (FR-CO07).
        let blocking = origin == .console && info?.flags.contains(.blocking) == true
        let reply = try await session.send(
            arguments, mayWrite: safetyClass.mayWrite, role: role, database: context.database,
            // Connection-state commands, pub/sub and MONITOR don't touch a database's data (EXEC runs what was checked
            // when queued), so they also run while a console's database is unknown.
            bindsDatabase: ![.session, .streaming].contains(safetyClass), selecting: Self.selecting(arguments, info, role),
            timeout: blocking ? RedisConnection.noTimeout : nil)
        if writes, ServerReadOnly.refusesWrites(reply, of: safetyClass) { writeObserver?(.serverRefused) }
        return DataCommandResult(reply: reply, safetyClass: safetyClass, role: role)
    }

    /// What the policy says about `command` now, sending nothing: the console asks first, so it can measure (FR-SF08) and
    /// confirm before the command runs. `execute` evaluates again, so a verdict here never lets anything through.
    public func verdict(_ command: DataCommand, origin: CommandOrigin, context: DataContext) -> SafetyVerdict {
        let arguments = command.arguments
        return SafetyPolicy.evaluate(
            arguments, command: catalog.resolve(arguments), origin: origin, profile: effective(context.profile), database: context.database,
            confirmation: context.confirmation)
    }

    /// A console's streaming command (`MONITOR`, `SUBSCRIBE`, … FR-CO07) on that console's `stream` connection: the
    /// server's confirmation and everything it sends after, until `stopStream(console:)`. Anything the policy doesn't
    /// class as streaming is refused here (`execute` runs it), sending nothing.
    public func stream(_ command: DataCommand, context: DataContext) async throws(DataCommandError) -> AsyncStream<RESPValue> {
        let arguments = command.arguments
        guard !arguments.isEmpty else { throw .invalidRequest("A command needs at least its name.") }
        let verdict = verdict(command, origin: .console, context: context)
        guard case .allow(let safetyClass) = verdict else { throw .refused(verdict) }
        guard safetyClass == .streaming else { throw .invalidRequest("Only MONITOR and the SUBSCRIBE commands stream.") }
        guard let console = context.consoleID else { throw .invalidRequest("A console command needs its console.") }
        return try await session.stream(arguments, role: .stream(console), database: context.database)
    }

    /// Stop (⌘.) for a console's stream: closes its `stream` connection, which ends the stream at once.
    public func stopStream(console: UUID) async { await session.close(.stream(console)) }

    /// Cancels a console's blocking command (FR-CO07) by closing its connection: the command fails (`OUTCOME_UNKNOWN`
    /// for a possible write, never re-sent) and the next one opens a new connection on the console's database.
    public func closeConsole(_ console: UUID) async {
        await session.close(.console(console))
        await session.close(.stream(console))
    }

    /// An editor's save (03 → Value editors, concurrency): `writes` apply together in one `MULTI … EXEC`. With
    /// `unchanged`, the key is `WATCH`ed and its reads are repeated first: a reply that differs from what the editor
    /// loaded, or a change before `EXEC`, writes nothing and throws `CONFLICT`. Without it (Overwrite) the writes still
    /// apply all or nothing. Every write and read passes the safety policy before the first byte is sent; `WATCH`,
    /// `MULTI`, `EXEC` and `UNWATCH` are the service's own framing on the browser connection, which callers can't send.
    ///
    /// The reply is `EXEC`'s (one reply per write, or `-EXECABORT …`), or a guard read's server error, which stops the
    /// save before anything is queued.
    public func executeTransaction(_ writes: [DataOperation], unchanged watch: WatchGuard?, context: DataContext) async throws(DataCommandError)
        -> DataCommandResult
    {
        do { return try await runTransaction(writes, unchanged: watch, context: context) } catch {
            if case .refused = error { Self.log.log(.info, "transaction.refused", .code(error.code)) } else { Self.log.error("transaction.failed", .code(error.code)) }
            throw error
        }
    }

    private func runTransaction(_ writes: [DataOperation], unchanged watch: WatchGuard?, context: DataContext) async throws(DataCommandError) -> DataCommandResult {
        guard !writes.isEmpty else { throw .invalidRequest("A save needs at least one write.") }
        if let watch, watch.reads.count != watch.expected.count { throw .invalidRequest("Each guard read needs the reply it expects.") }
        func evaluate(_ operation: DataOperation, confirmation: CommandConfirmation?) -> SafetyVerdict {
            let arguments = operation.arguments
            return SafetyPolicy.evaluate(
                arguments, command: catalog.resolve(arguments), origin: .editor, profile: effective(context.profile), database: context.database, confirmation: confirmation)
        }
        func checkWrites() throws(DataCommandError) {
            for write in writes {
                let verdict = evaluate(write, confirmation: context.confirmation)
                guard verdict.isAllowed else { throw .refused(verdict) }
            }
        }
        try checkWrites()
        for read in watch?.reads ?? [] {
            let verdict = evaluate(read, confirmation: nil)
            guard case .allow(let safetyClass) = verdict else { throw .refused(verdict) }
            // Repeating a write to compare its reply would change the key it guards.
            guard !safetyClass.mayWrite else { throw .invalidRequest("A guard read must not write.") }
        }
        let role = ConnectionRole.browser(database: context.database)
        await beginTransaction(role)
        defer { endTransaction(role) }
        // Re-checked after each wait (another save holding the connection, opening it, the guard reads): the profile may
        // have been made read-only meanwhile.
        if isReadOnlyLocked { try checkWrites() }
        let connection = try await session.pinnedConnection(for: role, database: context.database)
        let reply = try await transaction(writes, watch, on: connection) { () throws(DataCommandError) in if self.isReadOnlyLocked { try checkWrites() } }
        return DataCommandResult(reply: reply, safetyClass: .write, role: role)
    }

    private func transaction(
        _ writes: [DataOperation], _ watch: WatchGuard?, on connection: RedisConnection, recheck: () throws(DataCommandError) -> Void
    ) async throws(DataCommandError) -> RESPValue {
        func send(_ arguments: [Data]) async throws(DataCommandError) -> RESPValue {
            do throws(RedisError) { return try await connection.send(arguments, mayWrite: false) } catch { throw .command(error) }
        }
        // A WATCH left behind (a mismatch, a cancelled save) would make the next save's EXEC on this connection fail as a
        // false CONFLICT, so it is dropped before the role is handed on; in its own task, which a cancelled save can't stop.
        func unwatch() async { await Task { _ = try? await connection.send([d("UNWATCH")], mayWrite: false) }.value }
        if let watch {
            do throws(DataCommandError) {
                let watched = try await send([d("WATCH"), watch.key])
                if case .error = watched { return watched }
                for (read, expected) in zip(watch.reads, watch.expected) {
                    let reply = try await send(read.arguments)
                    // RESP2 and RESP3 spell a missing value (`$-1`, `_`) and a score (`$3 1.5`, `,1.5`) differently.
                    guard reply == expected || (reply.isNull && expected.isNull) || Self.sameScore(reply, expected), !Self.isError(reply) else {
                        await unwatch()
                        if Self.isError(reply) { return reply }
                        throw .conflict
                    }
                }
            } catch {
                // A dropped connection takes its WATCH with it; a cancelled wait leaves the connection and the WATCH.
                if error != .conflict { await unwatch() }
                throw error
            }
        }
        do throws(DataCommandError) { try recheck() } catch {
            if watch != nil { await unwatch() }
            throw error
        }
        writeObserver?(.sent)
        // One write, so nothing else on the browser connection can be queued inside this transaction.
        let replies: [Result<RESPValue, RedisError>]
        do throws(RedisError) {
            replies = try await connection.sendPipeline([[d("MULTI")]] + writes.map(\.arguments) + [[d("EXEC")]], mayWrite: true)
        } catch {
            // Thrown only before anything was sent (not connected, cancelled), so the WATCH is still there.
            if watch != nil { await unwatch() }
            throw .command(error)
        }
        // A write the server refused when queued (ACL, replica) aborts EXEC; one refused inside EXEC is in its array.
        let classes = writes.map { SafetyPolicy.classify($0.arguments, command: catalog.resolve($0.arguments)) }
        let queued = replies.dropFirst().dropLast().map { (try? $0.get()) ?? .null }
        var executed: [RESPValue] = []
        if case .success(.array(let items))? = replies.last { executed = items }
        if zip(queued, classes).contains(where: ServerReadOnly.refusesWrites) || zip(executed, classes).contains(where: ServerReadOnly.refusesWrites) {
            writeObserver?(.serverRefused)
        }
        // Without MULTI the writes ran one by one: what happened is unknown, so the editor re-reads.
        guard case .success(.simpleString) = replies.first else {
            if case .failure(let error) = replies.first { throw .command(error) }
            throw .command(.outcomeUnknown)
        }
        let exec: RESPValue
        do throws(RedisError) { exec = try replies[replies.count - 1].get() } catch { throw .command(error) }
        // A nil EXEC: a watched key changed after the reads, so the server ran none of the writes.
        if exec.isNull { throw .conflict }
        return exec
    }

    /// A RESP2 score (a bulk string such as `0.10000000000000001` or `inf`) equal to the RESP3 double a guard expects.
    static func sameScore(_ reply: RESPValue, _ expected: RESPValue) -> Bool {
        guard case .double(let score) = expected, case .bulkString(let text) = reply, let value = Double(String(decoding: text, as: UTF8.self)) else { return false }
        return value == score
    }

    private static func isError(_ reply: RESPValue) -> Bool {
        switch reply {
        case .error, .blobError: return true
        default: return false
        }
    }

    private func beginTransaction(_ role: ConnectionRole) async {
        guard !transacting.insert(role).inserted else { return }
        await withCheckedContinuation { waitingTransactions[role, default: []].append($0) }
    }

    /// Hands the role to the next waiting transaction, in arrival order.
    private func endTransaction(_ role: ConnectionRole) {
        guard var waiting = waitingTransactions[role], !waiting.isEmpty else { transacting.remove(role); return }
        let next = waiting.removeFirst()
        waitingTransactions[role] = waiting.isEmpty ? nil : waiting
        next.resume()
    }

    /// Replaces the catalog with the server's own merged over the bundled one (`COMMAND`, `COMMAND DOCS`), sent
    /// through this service like any other command. A server that refuses them keeps the bundled catalog.
    public func refreshCatalog(context: DataContext) async throws(DataCommandError) {
        // Same steps as `CommandCatalog.load`, but each command takes the policy path.
        let info = try await execute(.raw([d("COMMAND")]), origin: .browser, context: context).reply
        guard var live = CommandCatalog.live(commandReply: info) else { catalog = .bundled; return }
        live.attachDocs(docsReply: try await execute(.raw([d("COMMAND"), d("DOCS")]), origin: .browser, context: context).reply)
        catalog = CommandCatalog.bundled.merging(live: live)
    }

    /// The database a console's `SELECT n` / `RESET` moves its connection to (-1 when `n` isn't a number, which the
    /// server refuses); nil for every other command. Only the console sends these (they are session commands).
    static func selecting(_ arguments: [Data], _ info: CommandInfo?, _ role: ConnectionRole) -> Int? {
        guard case .console = role else { return nil }
        switch info?.name {
        case "select": return arguments.count == 2 ? Int(String(decoding: arguments[1], as: UTF8.self)) ?? -1 : -1
        case "reset": return 0
        default: return nil
        }
    }

    /// Editors and the browser share the database's browser connection; the console keeps its own (and a stream
    /// connection for MONITOR / SUBSCRIBE); each bulk job gets its own.
    static func role(for origin: CommandOrigin, _ safetyClass: SafetyClass, _ context: DataContext) throws(DataCommandError) -> ConnectionRole {
        switch origin {
        case .editor, .browser: return .browser(database: context.database)
        case .console:
            guard let console = context.consoleID else { throw .invalidRequest("A console command needs its console.") }
            return safetyClass == .streaming ? .stream(console) : .console(console)
        case .bulk:
            guard let job = context.jobID else { throw .invalidRequest("A bulk command needs its job.") }
            return .job(job)
        }
    }
}

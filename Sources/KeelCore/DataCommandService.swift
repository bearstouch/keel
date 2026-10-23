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
    /// `INFO section`; the database switcher asks for `keyspace` (FR-KB08).
    case info(section: Data)
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
    // Writes
    case stringSet(key: Data, value: Data, keepTTL: Bool)
    case hashSetField(key: Data, field: Data, value: Data)
    case hashDeleteFields(key: Data, fields: [Data])
    case listPush(key: Data, values: [Data], atHead: Bool)
    case listSet(key: Data, index: Int, value: Data)
    case listRemove(key: Data, count: Int, value: Data)
    case setAdd(key: Data, members: [Data])
    case setRemove(key: Data, members: [Data])
    case sortedSetAdd(key: Data, members: [ScoredMember])
    case sortedSetRemove(key: Data, members: [Data])
    case streamAdd(key: Data, id: Data, fields: [FieldValue])
    case streamDelete(key: Data, ids: [Data])
    case rename(key: Data, newKey: Data, overwrite: Bool)
    case expire(key: Data, milliseconds: Int64)
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
        case .info(let section): return [d("INFO"), section]
        case .objectEncoding(let key): return [d("OBJECT"), d("ENCODING"), key]
        case .length(let key, let command): return [d(command.rawValue), key]
        case .hashGetAll(let key): return [d("HGETALL"), key]
        case .hashScan(let key, let cursor, let count): return [d("HSCAN"), key, cursor, d("COUNT"), d(String(count))]
        case .hashGet(let key, let field): return [d("HGET"), key, field]
        case .stringSet(let key, let value, let keepTTL): return [d("SET"), key, value] + (keepTTL ? [d("KEEPTTL")] : [])
        case .hashSetField(let key, let field, let value): return [d("HSET"), key, field, value]
        case .hashDeleteFields(let key, let fields): return [d("HDEL"), key] + fields
        case .listPush(let key, let values, let atHead): return [d(atHead ? "LPUSH" : "RPUSH"), key] + values
        case .listSet(let key, let index, let value): return [d("LSET"), key, d(String(index)), value]
        case .listRemove(let key, let count, let value): return [d("LREM"), key, d(String(count)), value]
        case .setAdd(let key, let members): return [d("SADD"), key] + members
        case .setRemove(let key, let members): return [d("SREM"), key] + members
        case .sortedSetAdd(let key, let members): return [d("ZADD"), key] + members.flatMap { [d(Self.score($0.score)), $0.member] }
        case .sortedSetRemove(let key, let members): return [d("ZREM"), key] + members
        case .streamAdd(let key, let id, let fields): return [d("XADD"), key, id] + fields.flatMap { [$0.field, $0.value] }
        case .streamDelete(let key, let ids): return [d("XDEL"), key] + ids
        case .rename(let key, let newKey, let overwrite): return [d(overwrite ? "RENAME" : "RENAMENX"), key, newKey]
        case .expire(let key, let milliseconds): return [d("PEXPIRE"), key, d(String(milliseconds))]
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

/// The single entry point for every server command — editors, browser, console and bulk jobs
/// (02 Architecture → One data path). The policy decides before anything is written: a refused command opens no
/// connection and sends no byte.
public actor DataCommandService {
    public let session: ServerSession
    public private(set) var catalog: CommandCatalog

    /// Roles with a transaction in progress, and the transactions waiting for each. `EXEC` ends every `WATCH` on its
    /// connection, so two saves on the browser connection must not overlap.
    private var transacting: Set<ConnectionRole> = []
    private var waitingTransactions: [ConnectionRole: [CheckedContinuation<Void, Never>]] = [:]

    public init(session: ServerSession, catalog: CommandCatalog = .bundled) { self.session = session; self.catalog = catalog }

    public func execute(_ command: DataCommand, origin: CommandOrigin, context: DataContext) async throws(DataCommandError) -> DataCommandResult {
        let arguments = command.arguments
        guard !arguments.isEmpty else { throw .invalidRequest("A command needs at least its name.") }
        let info = catalog.resolve(arguments)
        let verdict = SafetyPolicy.evaluate(
            arguments, command: info, origin: origin, profile: context.profile, database: context.database, confirmation: context.confirmation)
        guard case .allow(let safetyClass) = verdict else { throw .refused(verdict) }
        let role = try Self.role(for: origin, safetyClass, context)
        let reply = try await session.send(
            arguments, mayWrite: safetyClass.mayWrite, role: role, database: context.database,
            // Connection-state commands, pub/sub and MONITOR don't touch a database's data (EXEC runs what was checked
            // when queued), so they also run while a console's database is unknown.
            bindsDatabase: ![.session, .streaming].contains(safetyClass), selecting: Self.selecting(arguments, info, role))
        return DataCommandResult(reply: reply, safetyClass: safetyClass, role: role)
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
        guard !writes.isEmpty else { throw .invalidRequest("A save needs at least one write.") }
        if let watch, watch.reads.count != watch.expected.count { throw .invalidRequest("Each guard read needs the reply it expects.") }
        func evaluate(_ operation: DataOperation, confirmation: CommandConfirmation?) -> SafetyVerdict {
            let arguments = operation.arguments
            return SafetyPolicy.evaluate(
                arguments, command: catalog.resolve(arguments), origin: .editor, profile: context.profile, database: context.database, confirmation: confirmation)
        }
        for write in writes {
            let verdict = evaluate(write, confirmation: context.confirmation)
            guard verdict.isAllowed else { throw .refused(verdict) }
        }
        for read in watch?.reads ?? [] {
            let verdict = evaluate(read, confirmation: nil)
            guard case .allow(let safetyClass) = verdict else { throw .refused(verdict) }
            // Repeating a write to compare its reply would change the key it guards.
            guard !safetyClass.mayWrite else { throw .invalidRequest("A guard read must not write.") }
        }
        let role = ConnectionRole.browser(database: context.database)
        await beginTransaction(role)
        defer { endTransaction(role) }
        let reply = try await transaction(writes, watch, on: try await session.pinnedConnection(for: role, database: context.database))
        return DataCommandResult(reply: reply, safetyClass: .write, role: role)
    }

    private func transaction(_ writes: [DataOperation], _ watch: WatchGuard?, on connection: RedisConnection) async throws(DataCommandError) -> RESPValue {
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
                    // RESP2 and RESP3 spell a missing value differently (`$-1`, `_`): both mean "absent".
                    guard reply == expected || (reply.isNull && expected.isNull), !Self.isError(reply) else {
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
        // One write, so nothing else on the browser connection can be queued inside this transaction.
        let replies: [Result<RESPValue, RedisError>]
        do throws(RedisError) {
            replies = try await connection.sendPipeline([[d("MULTI")]] + writes.map(\.arguments) + [[d("EXEC")]], mayWrite: true)
        } catch {
            // Thrown only before anything was sent (not connected, cancelled), so the WATCH is still there.
            if watch != nil { await unwatch() }
            throw .command(error)
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

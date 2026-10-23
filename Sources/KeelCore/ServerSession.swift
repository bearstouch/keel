import Foundation
import KeelRESP

/// Which connection of a session carries a command (02 Architecture → Connections), so long or stateful work never
/// blocks browsing.
public enum ConnectionRole: Sendable, Hashable, CustomStringConvertible {
    /// SCAN, TYPE/TTL pipelines, value pages and editor writes; one per database.
    case browser(database: Int)
    /// One per console; keeps its own `SELECT`, `CLIENT` and `MULTI` state.
    case console(UUID)
    /// MONITOR / SUBSCRIBE for one console, closed with Stop.
    case stream(UUID)
    /// One per bulk job (SCAN + UNLINK batches).
    case job(UUID)

    public var description: String {
        switch self {
        case .browser(let db): return "browser(db\(db))"
        case .console: return "console"
        case .stream: return "stream"
        case .job: return "job"
        }
    }
}

/// The connections of one server session, by role. Each is opened on first use; one that failed or closed is
/// replaced on the next use, and nothing that was in flight on it is ever re-sent (NFR-RL03).
public actor ServerSession {
    /// Opens a ready connection for `role`: connect, handshake, `SELECT database`. Injected so tests and profiles
    /// (TLS, tunnels) decide how.
    public typealias Open = @Sendable (ConnectionRole, _ database: Int) async throws(ConnectionFailure) -> RedisConnection

    private let open: Open
    private var connections: [ConnectionRole: RedisConnection] = [:]
    private var opening: [ConnectionRole: Task<Result<RedisConnection, ConnectionFailure>, Never>] = [:]
    /// The database each registered connection is on. Missing while a console's `SELECT` / `RESET` is in flight or
    /// queued in `MULTI`, so nothing but another `SELECT` runs until the console has chosen one again.
    private var databases: [ConnectionRole: Int] = [:]

    public init(open: @escaping Open) { self.open = open }

    /// Roles with a connection that is currently ready.
    public func readyRoles() async -> Set<ConnectionRole> {
        var ready: Set<ConnectionRole> = []
        for (role, connection) in connections where await connection.state == .ready { ready.insert(role) }
        return ready
    }

    /// The ready connection for `role`, opening one when there is none. `database` is used only when opening (the
    /// console keeps its own `SELECT` afterwards); concurrent callers share one open.
    public func connection(for role: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection {
        if let existing = connections[role], await existing.state == .ready { return existing }
        let task: Task<Result<RedisConnection, ConnectionFailure>, Never>
        if let running = opening[role] {
            task = running
        } else {
            let open = open
            task = Task { () async -> Result<RedisConnection, ConnectionFailure> in
                do throws(ConnectionFailure) { return .success(try await open(role, database)) } catch { return .failure(error) }
            }
            opening[role] = task
        }
        let result = await task.value
        // A failed open is forgotten too, so the next use tries again instead of replaying this failure forever.
        if case .failure = result, opening[role] == task { opening[role] = nil }
        let connection = try result.get()
        // Only the caller that finds its own open still registered records the result, so a close() in between wins.
        if opening[role] == task {
            opening[role] = nil
            let old = connections[role]
            connections[role] = connection; databases[role] = database
            if let old, old !== connection { await old.close() }
        } else if connections[role] !== connection {
            // The role was closed while this open ran: don't leak the late connection; sending on it is NOT_CONNECTED.
            await connection.close()
        }
        return connection
    }

    /// Sends on `role`'s connection, opening it first if needed. A command that `bindsDatabase` runs only when that
    /// connection is on `database` (a console's own `SELECT`, or a job id reused with another database, would otherwise
    /// aim it elsewhere); `selecting` marks a console `SELECT` / `RESET` that moves it there when the server says so.
    public func send(_ arguments: [Data], mayWrite: Bool, role: ConnectionRole, database: Int, bindsDatabase: Bool = true, selecting: Int? = nil)
        async throws(DataCommandError) -> RESPValue
    {
        let connection: RedisConnection
        do throws(ConnectionFailure) { connection = try await self.connection(for: role, database: database) } catch { throw .connection(error) }
        guard connections[role] === connection else { throw .command(.notConnected) }
        let previous = databases[role]
        if let selecting {
            // Unknown until the reply, so a command sent alongside can't run in a database it didn't name.
            databases[role] = nil
            let reply: RESPValue
            do throws(RedisError) { reply = try await connection.send(arguments, mayWrite: mayWrite) } catch { throw .command(error) }
            guard connections[role] === connection else { return reply }
            switch reply {
            case .simpleString(let text) where text == Data("OK".utf8) || text == Data("RESET".utf8): databases[role] = selecting
            case .error: databases[role] = previous
            default: break  // QUEUED in MULTI: whatever EXEC does, the console must SELECT again.
            }
            return reply
        }
        if bindsDatabase, previous != database { throw .invalidRequest("This connection is on another database; run SELECT \(database) first.") }
        do throws(RedisError) { return try await connection.send(arguments, mayWrite: mayWrite) } catch { throw .command(error) }
    }

    /// Closes `role`'s connection (Stop on a stream, a finished job, a closed console).
    public func close(_ role: ConnectionRole) async {
        opening[role]?.cancel(); opening[role] = nil; databases[role] = nil
        await connections.removeValue(forKey: role)?.close()
    }

    public func closeAll() async {
        for role in Set(connections.keys).union(opening.keys) { await close(role) }
    }
}

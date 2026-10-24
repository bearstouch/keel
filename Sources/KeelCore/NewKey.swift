import Foundation
import KeelRESP

/// The new-key sheet (FR-ED14): a key of any core type with its first value(s) and an optional TTL, created only when
/// the name is free. A string is one `SET … NX [PX ms]`; the other types are written in the shell's `WATCH` + `MULTI/EXEC`
/// guarded by `EXISTS` answering 0, so a key that exists (or appears before `EXEC`) is never touched.
public enum NewKey {
    /// The types the sheet's picker offers, in its order.
    public static let types: [KeyType] = [.string, .hash, .list, .set, .zset, .stream]

    public static let existsMessage = "Key already exists"

    /// The first value(s) of the new key, byte strings throughout.
    public enum Value: Sendable, Equatable {
        case string(Data)
        case hash([DataOperation.FieldValue])
        /// Head to tail.
        case list([Data])
        case set([Data])
        case sortedSet([DataOperation.ScoredMember])
        /// One entry: `*` (`StreamEditor.autoID`) or an explicit ID.
        case stream(id: Data, fields: [DataOperation.FieldValue])

        public var type: KeyType {
            switch self {
            case .string: return .string
            case .hash: return .hash
            case .list: return .list
            case .set: return .set
            case .sortedSet: return .zset
            case .stream: return .stream
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case created
        /// The name was taken; nothing was written.
        case exists
    }

    /// The name field's starting text: the selected namespace and the separator ("user:"), empty at the root.
    public static func prefill(namespace: Data?, separator: NamespaceSeparator) -> Data {
        guard let namespace, !namespace.isEmpty else { return Data() }
        return namespace + separator.bytes
    }

    /// Why the sheet's input can't be sent; nil when it can. Redis has no empty hash, list, set, sorted set or stream,
    /// so each needs at least one value; a string may be empty.
    public static func problem(key: Data, value: Value, ttlMilliseconds: Int64?) -> String? {
        if key.isEmpty { return "Enter a key name." }
        if let ttlMilliseconds, ttlMilliseconds <= 0 { return "A TTL must be longer than zero." }
        switch value {
        case .string: return nil
        case .hash(let fields):
            if fields.isEmpty { return "Add at least one field." }
            return fields.contains { $0.field.isEmpty } ? "Every field needs a name." : nil
        case .list(let items): return items.isEmpty ? "Add at least one item." : nil
        case .set(let members): return members.isEmpty ? "Add at least one member." : nil
        case .sortedSet(let members):
            if members.isEmpty { return "Add at least one member." }
            return members.contains { $0.score.isNaN } ? "A score is a number, inf or -inf." : nil
        case .stream(let id, let fields): return StreamEditor.problem(id: id, fields: fields)
        }
    }

    /// The writes that make the key; the TTL rides on `SET`'s `PX` for a string, else a `PEXPIRE` in the same `EXEC`.
    public static func writes(key: Data, value: Value, ttlMilliseconds: Int64?) -> [DataOperation] {
        let content: [DataOperation]
        switch value {
        case .string(let bytes): return [.stringCreate(key: key, value: bytes, milliseconds: ttlMilliseconds)]
        case .hash(let fields): content = fields.map { .hashSetField(key: key, field: $0.field, value: $0.value) }
        // RPUSH keeps the typed order head to tail.
        case .list(let items): content = [.listPush(key: key, values: items, atHead: false)]
        case .set(let members): content = [.setAdd(key: key, members: members)]
        case .sortedSet(let members): content = [.sortedSetAdd(key: key, members: members)]
        case .stream(let id, let fields): content = [.streamAdd(key: key, id: id, fields: fields)]
        }
        return content + (ttlMilliseconds.map { [.expire(key: key, milliseconds: $0)] } ?? [])
    }

    /// Creates `key` unless it exists. Every write passes the safety policy first, so a read-only profile sends nothing.
    /// A reply lost on the way stays `OUTCOME_UNKNOWN`: the key may exist now either way, so nothing is re-sent.
    public static func create(_ key: Data, _ value: Value, ttlMilliseconds: Int64? = nil, service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> Outcome
    {
        if let problem = problem(key: key, value: value, ttlMilliseconds: ttlMilliseconds) { throw .invalidRequest(problem) }
        let writes = writes(key: key, value: value, ttlMilliseconds: ttlMilliseconds)
        if case .string = value {
            // NX: one atomic command, nil when the name is taken.
            let reply = try await EditorReads.read(writes[0], service, context)
            if case .simpleString = reply { return .created }
            if reply.isNull { return .exists }
            throw EditorReads.unexpected(reply, type: "new key")
        }
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await service.executeTransaction(writes, unchanged: WatchGuard(key: key, reads: [.exists(key: key)], expected: [.integer(0)]), context: context).reply
        } catch {
            // EXISTS answered 1, or the key changed between WATCH and EXEC. Only a key that is there now is "exists".
            guard error == .conflict else { throw error }
            if case .integer(let count) = try await EditorReads.read(.exists(key: key), service, context), count > 0 { return .exists }
            throw error
        }
        // A guard read's error, `-EXECABORT …`, or a write that failed inside EXEC (an explicit stream ID the server refused).
        if let message = serverError(in: reply) { throw .invalidRequest(message) }
        return .created
    }

    private static func serverError(in reply: RESPValue) -> String? {
        switch reply {
        case .error(let text), .blobError(let text): return String(decoding: text.prefix(512), as: UTF8.self)
        case .array(let replies): return replies.lazy.compactMap(serverError(in:)).first
        default: return nil
        }
    }
}

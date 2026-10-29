import Foundation
import KeelRESP

/// The console's warning before an O(N) command on something large (FR-SF08): `KEYS` on a database, `SMEMBERS` /
/// `HGETALL` / an `LRANGE` reading more than 10,000 elements, `FLUSHALL` without `ASYNC`. The size is read first through
/// the data path (`DBSIZE`, `SCARD`, `HLEN`, `LLEN`, `INFO keyspace`); the console shows the warning and sends the
/// command only after the user goes on. Editors never send these unbounded, so only the console asks.
public struct ComplexityWarning: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keys(databaseSize: Int)
        /// `command` reads `elements` at once (`SMEMBERS`, `HGETALL`, `LRANGE`).
        case wholeValue(command: String, elements: Int)
        case flushAllSync(keys: Int)

        /// The measured size compared with `threshold`.
        var size: Int {
            switch self {
            case .keys(let count), .wholeValue(_, let count), .flushAllSync(let count): count
            }
        }
    }

    /// Sizes above this warn.
    public static let threshold = 10_000

    public var kind: Kind
    /// Names the command and the size; never a key name or value.
    public var message: String

    init(_ kind: Kind) {
        self.kind = kind
        switch kind {
        case .keys(let size):
            message = "KEYS walks all \(KeyIndexFooter.grouped(size)) keys of this database and blocks the server until it's done. The browser uses SCAN."
        case .wholeValue(let command, let elements):
            message = "\(command) reads \(KeyIndexFooter.grouped(elements)) elements at once and blocks the server while it does."
        case .flushAllSync(let keys):
            message = "FLUSHALL without ASYNC removes \(KeyIndexFooter.grouped(keys)) keys while the server blocks. FLUSHALL ASYNC frees them in the background."
        }
    }

    /// What to measure before `arguments` is sent; nil when the command never warns.
    enum Measure: Equatable {
        case databaseSize
        case length(key: Data, command: LengthCommand, display: String)
        /// `LRANGE key start stop`: the span is resolved against `LLEN` the way Redis does.
        case listRange(key: Data, start: Int, stop: Int)
        case allKeys
    }

    static func measure(_ arguments: [Data]) -> Measure? {
        guard let first = arguments.first else { return nil }
        let name = String(decoding: first, as: UTF8.self).lowercased()
        switch (name, arguments.count) {
        case ("keys", 2): return .databaseSize
        case ("smembers", 2): return .length(key: arguments[1], command: .scard, display: "SMEMBERS")
        case ("hgetall", 2): return .length(key: arguments[1], command: .hlen, display: "HGETALL")
        case ("lrange", 4):
            // Malformed bounds are the server's to refuse; nothing to warn about.
            guard let start = integer(arguments[2]), let stop = integer(arguments[3]) else { return nil }
            return .listRange(key: arguments[1], start: start, stop: stop)
        case ("flushall", _):
            // `FLUSHALL ASYNC` frees memory in the background; `SYNC` (6.2+) or no option blocks.
            let async = arguments.dropFirst().contains { String(decoding: $0, as: UTF8.self).lowercased() == "async" }
            return async ? nil : .allKeys
        default: return nil
        }
    }

    /// The warning for `arguments`, or nil when the command is cheap here, never warns, or its size couldn't be read
    /// (the policy's own confirmation for `KEYS` and `FLUSHALL` still applies). The size reads go through `service`
    /// from `origin` with `context`, so they run on the console's own connection and database. Inside that connection's
    /// `MULTI` nothing is measured: a size read would be queued in the user's transaction and add a reply to its `EXEC`.
    public static func check(_ arguments: [Data], service: DataCommandService, origin: CommandOrigin = .console, context: DataContext) async -> ComplexityWarning? {
        guard let measure = measure(arguments) else { return nil }
        if origin == .console, let console = context.consoleID, await service.inTransaction(console: console) { return nil }
        func size(_ operation: DataOperation) async -> Int? {
            guard case .integer(let value)? = try? await service.execute(.operation(operation), origin: origin, context: context).reply else { return nil }
            return Int(value)
        }
        let kind: Kind
        switch measure {
        case .databaseSize:
            guard let count = await size(.databaseSize) else { return nil }
            kind = .keys(databaseSize: count)
        case .length(let key, let command, let display):
            guard let count = await size(.length(key: key, command: command)) else { return nil }
            kind = .wholeValue(command: display, elements: count)
        case .listRange(let key, let start, let stop):
            guard let length = await size(.length(key: key, command: .llen)) else { return nil }
            kind = .wholeValue(command: "LRANGE", elements: span(start: start, stop: stop, length: length))
        case .allKeys:
            let info = try? await service.execute(.operation(.info(section: Data("keyspace".utf8))), origin: origin, context: context).reply
            guard let info, let text = InfoFields.text(of: info) else { return nil }
            kind = .flushAllSync(keys: DatabaseList.parseKeyspace(text).values.reduce(0) { $0 + $1.keys })
        }
        return kind.size > threshold ? ComplexityWarning(kind) : nil
    }

    /// How many elements `LRANGE start stop` returns from a list of `length` (negative indices count from the end).
    static func span(start: Int, stop: Int, length: Int) -> Int {
        let first = max(start < 0 ? length + start : start, 0)
        let last = min(stop < 0 ? length + stop : stop, length - 1)
        return max(last - first + 1, 0)
    }

    private static func integer(_ bytes: Data) -> Int? { Int(String(decoding: bytes, as: UTF8.self)) }
}

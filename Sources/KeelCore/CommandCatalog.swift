import Foundation
import KeelRESP

/// The catalog flags the safety policy and console read (02 Architecture → Safety policy). `dangerous` is the
/// server's `@dangerous` ACL category, which `admin` implies and which also covers some reads (`INFO`, `KEYS`).
public struct CommandFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let write = CommandFlags(rawValue: 1 << 0)
    public static let readonly = CommandFlags(rawValue: 1 << 1)
    public static let admin = CommandFlags(rawValue: 1 << 2)
    public static let dangerous = CommandFlags(rawValue: 1 << 3)
    public static let blocking = CommandFlags(rawValue: 1 << 4)
    public static let pubsub = CommandFlags(rawValue: 1 << 5)
    /// `may_replicate`: not flagged `write`, but may change what replicas see (`EVAL`, `FCALL`, `PUBLISH`); without
    /// `readonly` the safety policy treats it as a write.
    public static let mayReplicate = CommandFlags(rawValue: 1 << 6)

    /// Flags a server may add to a bundled command but never take away; `readonly` only relaxes, so it isn't one.
    public static let restrictive: CommandFlags = [.write, .admin, .dangerous, .blocking, .pubsub, .mayReplicate]

    static let names: [(String, CommandFlags)] = [
        ("write", .write), ("readonly", .readonly), ("admin", .admin), ("dangerous", .dangerous), ("blocking", .blocking), ("pubsub", .pubsub),
        ("may_replicate", .mayReplicate)
    ]

    /// Bundled names, or a live `COMMAND` reply's flags and ACL categories (`@dangerous`, and `@blocking` on 6.x,
    /// which has no `blocking` flag). Case-insensitive; anything else is ignored.
    init(names: some Sequence<String>) {
        var flags: CommandFlags = []
        for name in names {
            let lower = name.lowercased()
            let bare = lower.hasPrefix("@") ? String(lower.dropFirst()) : lower
            // Only the ACL categories that carry a flag count; `@write` etc. mirror the flags themselves.
            guard !lower.hasPrefix("@") || bare == "dangerous" || bare == "blocking" else { continue }
            if let flag = Self.names.first(where: { $0.0 == bare })?.1 { flags.insert(flag) }
        }
        // Redis puts every ADMIN command in @dangerous, so a reply lacking the category still means it.
        if flags.contains(.admin) { flags.insert(.dangerous) }
        self = flags
    }
}

/// How a command touches data. `.unknown` is never `.read`: an unclassified command fails closed (AC3).
public enum CommandAccess: String, Sendable, Equatable {
    /// `readonly` and not `write`.
    case read
    /// `write`, whatever else it says.
    case write
    /// Known, with neither flag (`PING`, `MULTI`, `EVAL`, `SUBSCRIBE`, `CLIENT LIST`): the policy decides from the
    /// other flags, the group and its fixed rules.
    case other
    /// Not in the server's or the bundled catalog, or an unknown subcommand of a known container.
    case unknown

    /// For `RedisConnection.send(_:mayWrite:)`: only a known read is safe to call a read when interrupted.
    public var mayWrite: Bool { self != .read }
}

/// One argument of a command's docs (`COMMAND DOCS` / the bundled `arguments`), nested for `oneof` and `block`.
public struct CommandArgument: Sendable, Equatable, Codable {
    public var name: String
    /// `key`, `string`, `integer`, `double`, `pattern`, `unix-time`, `pure-token`, `oneof` or `block`.
    public var type: String
    public var token: String?
    /// Shown instead of `name` (`display_text` live, `display` in the sources).
    public var display: String?
    public var optional: Bool
    public var multiple: Bool
    /// Each repetition repeats the token too (`[GET pattern [GET pattern ...]]`).
    public var multipleToken: Bool
    public var arguments: [CommandArgument]

    public init(
        name: String, type: String, token: String? = nil, display: String? = nil, optional: Bool = false, multiple: Bool = false, multipleToken: Bool = false,
        arguments: [CommandArgument] = []
    ) {
        self.name = name; self.type = type; self.token = token; self.display = display; self.optional = optional; self.multiple = multiple
        self.multipleToken = multipleToken; self.arguments = arguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name), type: try c.decode(String.self, forKey: .type), token: try c.decodeIfPresent(String.self, forKey: .token),
            display: try c.decodeIfPresent(String.self, forKey: .display), optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false,
            multiple: try c.decodeIfPresent(Bool.self, forKey: .multiple) ?? false, multipleToken: try c.decodeIfPresent(Bool.self, forKey: .multipleToken) ?? false,
            arguments: try c.decodeIfPresent([CommandArgument].self, forKey: .arguments) ?? [])
    }

    /// redis.io notation: `[optional]`, `<a | b>` for a required choice, `value [value ...]` for repeats.
    public var syntax: String {
        var text: String
        switch type {
        case "pure-token": text = token ?? name
        case "oneof":
            let choices = arguments.map(\.syntax).joined(separator: " | ")
            // A bare optional choice reads `[NX | XX]`; any other choice gets angle brackets (`TYPE <a | b>`).
            if optional && token == nil && !multiple { return "[\(choices)]" }
            text = "<\(choices)>"
        case "block": text = arguments.map(\.syntax).joined(separator: " ")
        default: text = display ?? name
        }
        if type != "pure-token", let token {
            let repeated = multipleToken ? "\(token) \(text)" : text
            text = "\(token) \(text)"
            if multiple { text += " [\(repeated) ...]" }
        } else if multiple {
            text += " [\(text) ...]"
        }
        return optional ? "[\(text)]" : text
    }
}

/// Human docs for completion hints (AC4).
public struct CommandDocs: Sendable, Equatable {
    public var summary: String?
    public var since: String?
    public var group: String?
    public var complexity: String?
    public var arguments: [CommandArgument]

    public init(summary: String? = nil, since: String? = nil, group: String? = nil, complexity: String? = nil, arguments: [CommandArgument] = []) {
        self.summary = summary; self.since = since; self.group = group; self.complexity = complexity; self.arguments = arguments
    }
}

/// One command or subcommand. `name` is lowercase, subcommands as `container|sub` (`client|list`) like `COMMAND`.
public struct CommandInfo: Sendable, Equatable {
    public var name: String
    /// Redis arity: N exact arguments (name included), -N at least N.
    public var arity: Int
    public var flags: CommandFlags
    /// Legacy key range as `COMMAND` reports it: 1-based positions in the full argument list, `lastKey` < 0 counts
    /// from the end, 0 / 0 / 0 means no keys.
    public var firstKey: Int
    public var lastKey: Int
    public var keyStep: Int
    /// Keys the range can't describe (`EVAL`, `ZUNIONSTORE`, `SORT … STORE`): the server must be asked.
    public var movableKeys: Bool
    public var docs: CommandDocs?

    public init(
        name: String, arity: Int, flags: CommandFlags, firstKey: Int = 0, lastKey: Int = 0, keyStep: Int = 0, movableKeys: Bool = false, docs: CommandDocs? = nil
    ) {
        self.name = name.lowercased(); self.arity = arity; self.flags = flags; self.firstKey = firstKey; self.lastKey = lastKey; self.keyStep = keyStep
        self.movableKeys = movableKeys; self.docs = docs
    }

    public var access: CommandAccess {
        if flags.contains(.write) { return .write }
        return flags.contains(.readonly) ? .read : .other
    }
    public var isSubcommand: Bool { name.contains("|") }
    /// `CLIENT LIST`.
    public var displayName: String { name.split(separator: "|").map { $0.uppercased() }.joined(separator: " ") }

    /// `SET key value [NX | XX] …`; just the name when no docs are known.
    public var syntax: String {
        let arguments = docs?.arguments.map(\.syntax) ?? []
        return ([displayName] + arguments).joined(separator: " ")
    }

    /// Whether `count` arguments (name and subcommand included) satisfy the arity.
    /// `magnitude` because a live arity is server data and `-Int.min` would trap.
    public func acceptsArgumentCount(_ count: Int) -> Bool { arity >= 0 ? count == arity : count >= 0 && count.magnitude >= arity.magnitude }

    /// 0-based indexes of the keys the legacy range names in a call with `count` arguments. Incomplete when
    /// `movableKeys` is set.
    public func keyIndexes(argumentCount count: Int) -> [Int] {
        guard firstKey > 0, keyStep > 0, firstKey < count else { return [] }
        let last = lastKey < 0 ? count + lastKey : min(lastKey, count - 1)
        guard last >= firstKey else { return [] }
        return Array(stride(from: firstKey, through: last, by: keyStep))
    }
}

/// Command metadata for the safety policy and the console (02 Architecture → Safety policy, INT-03): a bundled
/// catalog generated from Redis 7.4 and Valkey 8 (`Resources/Commands`, checked against Valkey 9), with the
/// server's own `COMMAND` / `COMMAND DOCS` merged over it when available.
public struct CommandCatalog: Sendable {
    public private(set) var commands: [String: CommandInfo]
    /// Top-level names that have subcommands (`client`, `xinfo`).
    public private(set) var containers: Set<String>

    public init(commands: some Sequence<CommandInfo>) {
        var byName: [String: CommandInfo] = [:]
        for command in commands { byName[command.name] = command }
        self.commands = byName
        self.containers = Set(byName.keys.compactMap { name in name.firstIndex(of: "|").map { String(name[..<$0]) } })
    }

    public var count: Int { commands.count }

    /// Top-level command names, sorted, for console completion.
    public var commandNames: [String] { commands.keys.filter { !$0.contains("|") }.sorted() }

    /// Subcommand names of `container` (`list`, `kill`, …), sorted.
    public func subcommandNames(of container: String) -> [String] {
        let prefix = container.lowercased() + "|"
        return commands.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    /// By catalog name: `get`, `client|list` (case-insensitive).
    public func command(named name: String) -> CommandInfo? { commands[name.lowercased()] }

    /// The command a call runs: the subcommand for a container (`CLIENT LIST`), else the command. Nil — unknown — for
    /// an unknown name, an unknown subcommand of a known container, and a name that isn't a plain ASCII token
    /// (`client|list` sent as one argument is not `CLIENT LIST` to the server, so it isn't to the catalog either).
    public func resolve(_ arguments: [Data]) -> CommandInfo? {
        guard let first = arguments.first, let name = Self.commandName(first) else { return nil }
        if containers.contains(name), arguments.count >= 2 {
            guard let sub = Self.commandName(arguments[1]) else { return nil }
            return commands["\(name)|\(sub)"]
        }
        // A bare container (`CLIENT`) is its own entry; the server answers it with an arity error.
        return commands[name]
    }

    public func access(of arguments: [Data]) -> CommandAccess { resolve(arguments)?.access ?? .unknown }

    /// Lowercased name when every byte is a printable ASCII character other than `|` and space; names are short.
    private static func commandName(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.count <= 64, bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "|") }) else { return nil }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }

    /// `live` over `self`: live entries replace bundled ones of the same name (arity, keys, docs when it has them)
    /// and add the ones the bundle lacks (modules, newer servers). A server can add a restrictive flag but never take
    /// one away, nor add `readonly` to a bundled command, so a misreporting server can't turn `FLUSHALL` or `EVAL`
    /// into a read.
    public func merging(live: CommandCatalog) -> CommandCatalog {
        var merged = commands
        for (name, var command) in live.commands {
            if let bundled = commands[name] {
                command.flags.formUnion(bundled.flags.intersection(.restrictive))
                // `readonly` only relaxes: a server can't turn a bundled non-read (`EVAL`, `PUBLISH`) into a read.
                if !bundled.flags.contains(.readonly) { command.flags.remove(.readonly) }
                if command.docs == nil { command.docs = bundled.docs }
            }
            merged[name] = command
        }
        return CommandCatalog(commands: merged.values)
    }
}

// MARK: - Bundled catalog

extension CommandCatalog {
    /// `Resources/Commands/commands.json` as written by `scripts/generate-command-catalog.py`.
    struct BundledFile: Decodable {
        struct Entry: Decodable {
            var name: String
            var arity: Int
            var flags: [String]
            var firstKey: Int
            var lastKey: Int
            var step: Int
            var movableKeys: Bool?
            var group: String?
            var since: String?
            var summary: String?
            var complexity: String?
            var arguments: [CommandArgument]?
        }

        var version: Int
        var generatedFrom: [String]
        var checkedAgainst: String
        var commands: [Entry]
    }

    /// The bundled format this build reads; a generator change that alters the shape bumps both.
    public static let bundledFormatVersion = 1

    /// The catalog bundled with Keel. A missing, broken or newer resource is a build defect, caught by
    /// `CommandCatalogTests`.
    static var bundledURL: URL? { Bundle.keelCore.url(forResource: "commands", withExtension: "json", subdirectory: "Commands") }

    public static let bundled: CommandCatalog = {
        guard let url = bundledURL, let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(BundledFile.self, from: data), file.version == bundledFormatVersion
        else { preconditionFailure("Resources/Commands/commands.json is missing or invalid") }
        return CommandCatalog(
            commands: file.commands.map { entry in
                CommandInfo(
                    name: entry.name, arity: entry.arity, flags: CommandFlags(names: entry.flags), firstKey: entry.firstKey, lastKey: entry.lastKey,
                    keyStep: entry.step, movableKeys: entry.movableKeys ?? false,
                    docs: CommandDocs(summary: entry.summary, since: entry.since, group: entry.group, complexity: entry.complexity, arguments: entry.arguments ?? []))
            })
    }()
}

// MARK: - Live catalog

extension CommandCatalog {
    /// Sends one Keel metadata command on the session's connection and returns its reply (server errors as values).
    public typealias Send = @Sendable ([Data]) async throws(RedisError) -> RESPValue

    /// Server-reported commands beyond this are dropped; real servers report a few hundred.
    static let maxLiveCommands = 10_000

    /// `bundled` with the server's catalog merged over it. `COMMAND` (every command, 6.0+; same entries as
    /// `COMMAND INFO`) gives flags and keys, `COMMAND DOCS` (7.0+) the docs. A server that refuses either (renamed,
    /// ACL `NOPERM`, Dragonfly without docs) keeps the bundled data for it; connection errors throw.
    public static func load(bundled: CommandCatalog = .bundled, send: Send) async throws(RedisError) -> CommandCatalog {
        guard var live = live(commandReply: try await send([Data("COMMAND".utf8)])) else { return bundled }
        let docs = try await send([Data("COMMAND".utf8), Data("DOCS".utf8)])
        live.attachDocs(docsReply: docs)
        return bundled.merging(live: live)
    }

    /// A `COMMAND` / `COMMAND INFO` reply (RESP2 or RESP3) as a catalog; nil for an error or anything not an array.
    /// Malformed entries are skipped, and `COMMAND INFO`'s nulls for unknown names are ignored.
    public static func live(commandReply reply: RESPValue) -> CommandCatalog? {
        guard let entries = LiveReply.list(reply) else { return nil }
        var commands: [CommandInfo] = []
        func add(_ entries: [RESPValue]) {
            for entry in entries where commands.count < maxLiveCommands {
                guard let fields = LiveReply.list(entry), let command = command(fields) else { continue }
                commands.append(command)
                // 7.0+: subcommands nest in field 9 with the same shape, named `container|sub`.
                if fields.count > 9, let subcommands = LiveReply.list(fields[9]) { add(subcommands) }
            }
        }
        add(entries)
        return CommandCatalog(commands: commands)
    }

    /// `[name, arity, flags, first, last, step, acl categories?, …]`.
    private static func command(_ fields: [RESPValue]) -> CommandInfo? {
        guard fields.count >= 6, let name = LiveReply.string(fields[0]), !name.isEmpty, let arity = LiveReply.int(fields[1]),
            let first = LiveReply.int(fields[3]), let last = LiveReply.int(fields[4]), let step = LiveReply.int(fields[5])
        else { return nil }
        let flagNames = (LiveReply.list(fields[2]) ?? []).compactMap(LiveReply.string)
        let categories = fields.count > 6 ? (LiveReply.list(fields[6]) ?? []).compactMap(LiveReply.string) : []
        return CommandInfo(
            name: name, arity: arity, flags: CommandFlags(names: flagNames + categories), firstKey: first, lastKey: last, keyStep: step,
            movableKeys: flagNames.contains { $0.lowercased() == "movablekeys" })
    }

    /// Adds `COMMAND DOCS` to the commands this catalog already has; an error reply or unknown name changes nothing.
    mutating func attachDocs(docsReply reply: RESPValue) {
        func attach(_ reply: RESPValue) {
            for (name, value) in LiveReply.pairs(reply) ?? [] {
                guard let name = LiveReply.string(name)?.lowercased(), let fields = LiveReply.fields(value) else { continue }
                commands[name]?.docs = Self.docs(fields)
                // Subcommands of a container are a nested map keyed `container|sub`, the same as COMMAND names.
                if let subcommands = fields["subcommands"] { attach(subcommands) }
            }
        }
        attach(reply)
    }

    private static func docs(_ fields: [String: RESPValue]) -> CommandDocs {
        CommandDocs(
            summary: fields["summary"].flatMap(LiveReply.string), since: fields["since"].flatMap(LiveReply.string), group: fields["group"].flatMap(LiveReply.string),
            complexity: fields["complexity"].flatMap(LiveReply.string), arguments: arguments(fields["arguments"], depth: 0))
    }

    /// Argument maps (`name`, `type`, `token`, `display_text`, `flags`, `arguments`). Nesting past 16 is dropped; real
    /// docs nest at most 3 deep.
    private static func arguments(_ value: RESPValue?, depth: Int) -> [CommandArgument] {
        guard depth < 16, let value, let list = LiveReply.list(value) else { return [] }
        return list.compactMap { item in
            guard let fields = LiveReply.fields(item), let name = fields["name"].flatMap(LiveReply.string), let type = fields["type"].flatMap(LiveReply.string)
            else { return nil }
            let flags = Set((fields["flags"].flatMap(LiveReply.list) ?? []).compactMap(LiveReply.string).map { $0.lowercased() })
            return CommandArgument(
                name: name, type: type, token: fields["token"].flatMap(LiveReply.string), display: fields["display_text"].flatMap(LiveReply.string),
                optional: flags.contains("optional"), multiple: flags.contains("multiple"), multipleToken: flags.contains("multiple_token"),
                arguments: arguments(fields["arguments"], depth: depth + 1))
        }
    }
}

/// Reading `COMMAND` replies the same way over RESP2 and RESP3: arrays or sets, maps or flat key-value arrays,
/// bulk, simple or verbatim strings, attributes unwrapped.
enum LiveReply {
    static func unwrap(_ value: RESPValue) -> RESPValue {
        if case .attribute(_, let inner) = value { return unwrap(inner) }
        return value
    }

    static func list(_ value: RESPValue) -> [RESPValue]? {
        switch unwrap(value) {
        case .array(let items), .set(let items): return items
        default: return nil
        }
    }

    /// A RESP3 map, or a RESP2 flat `[key, value, …]` array.
    static func pairs(_ value: RESPValue) -> [(RESPValue, RESPValue)]? {
        switch unwrap(value) {
        case .map(let pairs): return pairs.map { ($0.key, $0.value) }
        case .array(let items) where items.count % 2 == 0: return stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
        default: return nil
        }
    }

    /// String-keyed fields of a map; the first of a repeated key wins.
    static func fields(_ value: RESPValue) -> [String: RESPValue]? {
        guard let pairs = pairs(value) else { return nil }
        var fields: [String: RESPValue] = [:]
        for (key, value) in pairs { if let key = string(key), fields[key] == nil { fields[key] = value } }
        return fields
    }

    static func string(_ value: RESPValue) -> String? {
        switch unwrap(value) {
        case .bulkString(let bytes), .simpleString(let bytes), .verbatim(_, let bytes): return String(decoding: bytes, as: UTF8.self)
        default: return nil
        }
    }

    static func int(_ value: RESPValue) -> Int? {
        if case .integer(let number) = unwrap(value) { return Int(exactly: number) }
        return nil
    }
}

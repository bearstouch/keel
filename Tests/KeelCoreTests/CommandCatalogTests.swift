import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

private actor Sent {
    var commands: [[Data]] = []
    func append(_ arguments: [Data]) { commands.append(arguments) }
}

final class CommandCatalogTests: XCTestCase {
    private let catalog = CommandCatalog.bundled

    static func args(_ words: String...) -> [Data] { words.map { Data($0.utf8) } }
    /// `"CLIENT LIST"` as the arguments `CLIENT`, `LIST`.
    static func args(splitting command: String) -> [Data] { command.split(separator: " ").map { Data($0.utf8) } }

    /// A captured server reply in `Tests/Fixtures/Commands`, parsed with Keel's own RESP parser.
    static func fixture(_ name: String) throws -> RESPValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Commands/\(name)")
        var parser = RESPParser()
        parser.append(try Data(contentsOf: url))
        return try XCTUnwrap(try parser.next(), name)
    }

    // MARK: - Story tests

    /// Every command the browser and the editors send (03 Functional requirements → Key browser, Value editors).
    static let editorCommands: [(String, CommandAccess)] = [
        // Browser and header metadata
        ("SCAN", .read), ("TYPE", .read), ("EXISTS", .read), ("PTTL", .read), ("PEXPIRETIME", .read), ("DBSIZE", .read),
        ("MEMORY USAGE", .read), ("OBJECT ENCODING", .read), ("SELECT", .other), ("PING", .other), ("INFO", .other),
        // Common key actions and multi-step edits
        ("UNLINK", .write), ("DEL", .write), ("RENAME", .write), ("RENAMENX", .write), ("PEXPIRE", .write), ("PEXPIREAT", .write),
        ("PERSIST", .write), ("COPY", .write), ("WATCH", .other), ("UNWATCH", .other), ("MULTI", .other), ("EXEC", .other), ("DISCARD", .other),
        // String
        ("GET", .read), ("GETRANGE", .read), ("STRLEN", .read), ("SET", .write),
        // Hash
        ("HSCAN", .read), ("HLEN", .read), ("HGET", .read), ("HSET", .write), ("HSETNX", .write), ("HDEL", .write),
        // List
        ("LLEN", .read), ("LRANGE", .read), ("LINDEX", .read), ("LSET", .write), ("LINSERT", .write), ("LPUSH", .write), ("RPUSH", .write),
        ("LPOP", .write), ("RPOP", .write), ("LREM", .write),
        // Set
        ("SSCAN", .read), ("SCARD", .read), ("SISMEMBER", .read), ("SADD", .write), ("SREM", .write),
        // Sorted set (ZRANGEBYSCORE is the 6.0 fallback)
        ("ZSCAN", .read), ("ZCARD", .read), ("ZSCORE", .read), ("ZRANGE", .read), ("ZRANGEBYSCORE", .read), ("ZADD", .write), ("ZINCRBY", .write),
        ("ZREM", .write),
        // Stream
        ("XLEN", .read), ("XRANGE", .read), ("XREVRANGE", .read), ("XINFO STREAM", .read), ("XADD", .write), ("XDEL", .write),
        // Read-only scripts
        ("EVAL_RO", .read), ("FCALL_RO", .read)
    ]

    func testEditorCommandsAreClassified() {
        for (command, expected) in Self.editorCommands {
            let arguments = Self.args(splitting: command)
            let info = catalog.resolve(arguments)
            XCTAssertNotNil(info, command)
            XCTAssertEqual(info?.displayName, command)
            XCTAssertEqual(catalog.access(of: arguments), expected, command)
            XCTAssertNotNil(info?.docs?.summary, "\(command) has docs")
        }
    }

    func testFlagsForReferenceCommands() {
        let table: [(String, CommandAccess, CommandFlags)] = [
            ("SET", .write, [.write]),
            ("GET", .read, [.readonly]),
            ("FLUSHALL", .write, [.write, .dangerous]),
            ("FLUSHDB", .write, [.write, .dangerous]),
            ("SUBSCRIBE", .other, [.pubsub]),
            ("PSUBSCRIBE", .other, [.pubsub]),
            ("SSUBSCRIBE", .other, [.pubsub]),
            ("BLPOP", .write, [.write, .blocking]),
            ("XREAD", .read, [.readonly, .blocking]),
            ("KEYS", .read, [.readonly, .dangerous]),
            ("MONITOR", .other, [.admin, .dangerous]),
            ("SHUTDOWN", .other, [.admin, .dangerous]),
            ("CONFIG SET", .other, [.admin, .dangerous]),
            ("DEBUG", .other, [.admin, .dangerous]),
            ("SWAPDB", .write, [.write, .dangerous]),
            ("MIGRATE", .write, [.write, .dangerous]),
            ("EVAL", .other, []),
            ("EVAL_RO", .read, [.readonly]),
            ("FCALL_RO", .read, [.readonly])
        ]
        for (command, access, flags) in table {
            let arguments = Self.args(splitting: command)
            XCTAssertEqual(catalog.resolve(arguments)?.flags, flags, command)
            XCTAssertEqual(catalog.access(of: arguments), access, command)
        }
        XCTAssertEqual(catalog.command(named: "set")?.arity, -3)
        XCTAssertEqual(catalog.command(named: "client|list")?.flags, [.admin, .dangerous])
    }

    func testUnknownCommandFailsClosed() {
        for arguments in [
            Self.args("NOSUCHCOMMAND"), Self.args("CLIENT", "NOSUCHSUB"), Self.args("XINFO", "nosuch", "key"),
            // A subcommand's catalog name sent as one argument is unknown to the server, so it is to Keel too.
            Self.args("client|list"), Self.args("GET ", "k"), Self.args(""), [], [Data([0x47, 0x45, 0x54, 0xFF])]
        ] {
            XCTAssertNil(catalog.resolve(arguments), "\(arguments)")
            XCTAssertEqual(catalog.access(of: arguments), .unknown)
            XCTAssertTrue(catalog.access(of: arguments).mayWrite, "unknown is never treated as a read")
        }
        XCTAssertFalse(CommandAccess.read.mayWrite)
        XCTAssertEqual(CommandCatalog(commands: []).access(of: Self.args("GET", "k")), .unknown, "an empty catalog knows nothing")
    }

    func testLiveCatalogOverridesBundled() throws {
        let live = CommandCatalog(commands: [
            // A newer server changes arity and docs of a bundled command.
            CommandInfo(name: "GET", arity: -2, flags: [.readonly], firstKey: 1, lastKey: 1, keyStep: 1, docs: CommandDocs(summary: "live summary")),
            // A module adds a command the bundle doesn't know.
            CommandInfo(name: "json.set", arity: -4, flags: [.write], firstKey: 1, lastKey: 1, keyStep: 1),
            // A server that misreports a destructive command can't make it a read.
            CommandInfo(name: "flushall", arity: -1, flags: [.readonly]),
            // A live entry without docs (Redis 6 has no COMMAND DOCS) keeps the bundled docs.
            CommandInfo(name: "set", arity: -3, flags: [.write, .blocking])
        ])
        let merged = catalog.merging(live: live)
        XCTAssertEqual(merged.command(named: "get")?.arity, -2)
        XCTAssertEqual(merged.command(named: "get")?.docs?.summary, "live summary")
        XCTAssertEqual(merged.access(of: Self.args("JSON.SET", "k", "$", "1")), .write)
        XCTAssertEqual(catalog.access(of: Self.args("JSON.SET", "k", "$", "1")), .unknown, "the bundle alone doesn't know it")
        XCTAssertEqual(merged.command(named: "flushall")?.flags, [.write, .dangerous])
        XCTAssertEqual(merged.access(of: Self.args("FLUSHALL")), .write)
        XCTAssertEqual(merged.command(named: "set")?.flags, [.write, .blocking], "a live restriction is kept")
        XCTAssertEqual(merged.command(named: "set")?.docs, catalog.command(named: "set")?.docs)
        XCTAssertEqual(merged.count, catalog.count + 1)
        XCTAssertEqual(merged.command(named: "xinfo|stream"), catalog.command(named: "xinfo|stream"), "bundled-only commands remain")
    }

    func testSubcommandLookup() {
        let list = catalog.resolve(Self.args("client", "list"))
        XCTAssertEqual(list?.name, "client|list")
        XCTAssertEqual(list?.displayName, "CLIENT LIST")
        XCTAssertTrue(list?.isSubcommand ?? false)
        let stream = catalog.resolve(Self.args("XINFO", "STREAM", "orders", "FULL"))
        XCTAssertEqual(stream?.name, "xinfo|stream")
        XCTAssertEqual(stream?.access, .read)
        XCTAssertEqual(stream?.keyIndexes(argumentCount: 4), [2])
        XCTAssertEqual(catalog.resolve(Self.args("CONFIG", "GET", "maxmemory"))?.name, "config|get")
        XCTAssertEqual(catalog.resolve(Self.args("Memory", "Usage", "k"))?.access, .read)
        // A bare container is its own entry (no flags); the server rejects it on arity.
        XCTAssertEqual(catalog.resolve(Self.args("CLIENT"))?.name, "client")
        XCTAssertTrue(catalog.containers.isSuperset(of: ["client", "xinfo", "config", "object", "memory", "script", "function", "acl", "cluster"]))
        XCTAssertTrue(catalog.subcommandNames(of: "XINFO").contains("stream"))
        XCTAssertFalse(catalog.commandNames.contains { $0.contains("|") })
        XCTAssertTrue(catalog.commandNames.contains("get"))
    }

    // MARK: - Docs (AC4)

    func testDocsGiveArgumentSyntax() {
        let syntax: [(String, String)] = [
            ("set", "SET key value [NX | XX] [GET] [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL]"),
            ("xinfo|stream", "XINFO STREAM key [FULL [COUNT count]]"),
            ("client|list", "CLIENT LIST [TYPE <normal | master | replica | pubsub>] [ID client-id [client-id ...]]"),
            ("zadd", "ZADD key [NX | XX] [GT | LT] [CH] [INCR] score member [score member ...]"),
            ("del", "DEL key [key ...]"),
            ("bitop", "BITOP <AND | OR | XOR | NOT> destkey key [key ...]"),
            ("ping", "PING [message]")
        ]
        for (name, expected) in syntax {
            XCTAssertEqual(catalog.command(named: name)?.syntax, expected, name)
        }
        let sort = catalog.command(named: "sort")?.syntax ?? ""
        XCTAssertTrue(sort.contains("[GET pattern [GET pattern ...]]"), sort)
        XCTAssertEqual(catalog.command(named: "set")?.docs?.group, "string")
        XCTAssertEqual(catalog.command(named: "set")?.docs?.complexity, "O(1)")
        XCTAssertEqual(CommandInfo(name: "x", arity: 1, flags: []).syntax, "X", "no docs: just the name")
    }

    // MARK: - Live replies

    func testLiveRepliesParseOverRESP2AndRESP3() throws {
        for resp in ["resp2", "resp3"] {
            var live = try XCTUnwrap(CommandCatalog.live(commandReply: Self.fixture("redis-7.2-command-info.\(resp)")), resp)
            live.attachDocs(docsReply: try Self.fixture("redis-7.2-command-docs.\(resp)"))
            XCTAssertEqual(live.access(of: Self.args("GET", "k")), .read, resp)
            XCTAssertEqual(live.command(named: "set")?.flags, [.write], resp)
            XCTAssertEqual(live.command(named: "flushall")?.flags, [.write, .dangerous], resp)
            XCTAssertEqual(live.command(named: "subscribe")?.flags, [.pubsub], resp)
            XCTAssertEqual(live.command(named: "blpop")?.flags, [.write, .blocking], resp)
            XCTAssertEqual(live.command(named: "blpop")?.keyIndexes(argumentCount: 4), [1, 2], resp)
            XCTAssertEqual(live.resolve(Self.args("CLIENT", "LIST"))?.flags, [.admin, .dangerous], resp)
            XCTAssertEqual(live.resolve(Self.args("XINFO", "STREAM", "k"))?.access, .read, resp)
            // Docs, including a container's subcommands, match the bundled rendering of the same commands.
            XCTAssertEqual(live.command(named: "set")?.syntax, catalog.command(named: "set")?.syntax, resp)
            XCTAssertEqual(live.command(named: "xinfo|stream")?.syntax, "XINFO STREAM key [FULL [COUNT count]]", resp)
            XCTAssertEqual(live.command(named: "client|list")?.docs?.summary, "Lists open connections.", resp)
            XCTAssertNil(live.command(named: "get")?.docs, "GET wasn't asked for docs")
        }
    }

    func testMalformedLiveRepliesAreIgnored() {
        XCTAssertNil(CommandCatalog.live(commandReply: .error(Data("ERR unknown command 'COMMAND'".utf8))))
        XCTAssertNil(CommandCatalog.live(commandReply: .bulkString(Data("x".utf8))))
        let reply = RESPValue.array([
            .nullArray,  // COMMAND INFO's answer for an unknown name
            .array([.bulkString(Data("short".utf8)), .integer(1)]),
            .array([.integer(5), .integer(1), .array([]), .integer(0), .integer(0), .integer(0)]),
            .array([.bulkString(Data("ok".utf8)), .integer(1), .set([.simpleString(Data("readonly".utf8))]), .integer(0), .integer(0), .integer(0)])
        ])
        let live = CommandCatalog.live(commandReply: reply)
        XCTAssertEqual(live?.count, 1)
        XCTAssertEqual(live?.access(of: Self.args("OK")), .read)
        // Redis 6 has no `blocking` flag; its `@blocking` ACL category carries it, and ADMIN always means dangerous.
        let redis6 = RESPValue.array([
            .array([
                .simpleString(Data("brpop".utf8)), .integer(-3), .array([.simpleString(Data("write".utf8)), .simpleString(Data("noscript".utf8))]),
                .integer(1), .integer(-2), .integer(1), .array([.simpleString(Data("@write".utf8)), .simpleString(Data("@blocking".utf8))])
            ]),
            .array([.simpleString(Data("debug".utf8)), .integer(-2), .array([.simpleString(Data("admin".utf8))]), .integer(0), .integer(0), .integer(0)])
        ])
        let six = CommandCatalog.live(commandReply: redis6)
        XCTAssertEqual(six?.command(named: "brpop")?.flags, [.write, .blocking])
        XCTAssertEqual(six?.command(named: "debug")?.flags, [.admin, .dangerous])
        var docs = CommandCatalog(commands: [CommandInfo(name: "get", arity: 2, flags: [.readonly])])
        docs.attachDocs(docsReply: .error(Data("ERR unknown subcommand 'DOCS'".utf8)))
        XCTAssertNil(docs.command(named: "get")?.docs)
    }

    func testLoadMergesLiveOverBundledAndFallsBack() async throws {
        let info = try Self.fixture("redis-7.2-command-info.resp3"), docs = try Self.fixture("redis-7.2-command-docs.resp3")
        let sent = Sent()
        let loaded = try await CommandCatalog.load { (arguments: [Data]) async throws(RedisError) -> RESPValue in
            await sent.append(arguments)
            return arguments.count == 1 ? info : docs
        }
        let commands = await sent.commands
        XCTAssertEqual(commands, [Self.args("COMMAND"), Self.args("COMMAND", "DOCS")])
        XCTAssertEqual(loaded.count, catalog.count, "every live command is also bundled")
        XCTAssertEqual(loaded.command(named: "client|list")?.docs?.summary, "Lists open connections.")
        // A server that refuses COMMAND (renamed, ACL NOPERM) leaves the bundled catalog in charge.
        let refused = try await CommandCatalog.load { (_: [Data]) async throws(RedisError) -> RESPValue in .error(Data("NOPERM no permission".utf8)) }
        XCTAssertEqual(refused.count, catalog.count)
        XCTAssertEqual(refused.command(named: "set"), catalog.command(named: "set"))
        // A connection failure is the caller's to handle, not a silent fallback.
        do {
            _ = try await CommandCatalog.load { (_: [Data]) async throws(RedisError) -> RESPValue in throw RedisError.notConnected }
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error, .notConnected)
        }
    }

    // MARK: - Bundled file

    func testBundledCatalogIsVersionedAndComplete() throws {
        let url = try XCTUnwrap(CommandCatalog.bundledURL)
        let file = try JSONDecoder().decode(CommandCatalog.BundledFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.version, CommandCatalog.bundledFormatVersion)
        XCTAssertEqual(file.generatedFrom.map { $0.split(separator: " ")[0] }, ["redis", "valkey"])
        XCTAssertTrue(file.generatedFrom[0].hasPrefix("redis 7.4"))
        XCTAssertTrue(file.generatedFrom[1].hasPrefix("valkey 8"))
        XCTAssertTrue(file.checkedAgainst.hasPrefix("valkey 9"))
        XCTAssertGreaterThan(catalog.count, 350)
        // Every subcommand has its container, so container lookup can't miss one.
        for name in catalog.commands.keys where name.contains("|") {
            XCTAssertNotNil(catalog.command(named: String(name.split(separator: "|")[0])), name)
        }
        // Valkey-only and Redis-only commands are both present; Sentinel-only ones are not.
        XCTAssertNotNil(catalog.command(named: "client|capa"))
        XCTAssertNotNil(catalog.command(named: "hexpire"))
        XCTAssertNil(catalog.command(named: "sentinel"))
    }

    // MARK: - Keys

    func testKeyIndexes() {
        XCTAssertEqual(catalog.command(named: "get")?.keyIndexes(argumentCount: 2), [1])
        XCTAssertEqual(catalog.command(named: "del")?.keyIndexes(argumentCount: 4), [1, 2, 3])
        XCTAssertEqual(catalog.command(named: "mset")?.keyIndexes(argumentCount: 5), [1, 3])
        XCTAssertEqual(catalog.command(named: "blpop")?.keyIndexes(argumentCount: 4), [1, 2], "the timeout isn't a key")
        XCTAssertEqual(catalog.command(named: "ping")?.keyIndexes(argumentCount: 1), [])
        XCTAssertEqual(catalog.command(named: "get")?.keyIndexes(argumentCount: 1), [], "a short call names no key")
        XCTAssertTrue(catalog.command(named: "eval")?.movableKeys ?? false)
        XCTAssertTrue(catalog.command(named: "get")?.acceptsArgumentCount(2) ?? false)
        XCTAssertFalse(catalog.command(named: "get")?.acceptsArgumentCount(3) ?? true)
        XCTAssertTrue(catalog.command(named: "del")?.acceptsArgumentCount(5) ?? false)
        XCTAssertFalse(catalog.command(named: "del")?.acceptsArgumentCount(1) ?? true)
    }
}

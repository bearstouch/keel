import Foundation
import KeelCore
import KeelRESP
import XCTest

/// KEEL-048 AC1 + AC2: every engine of the container matrix (Redis 6.0 – 8.x, Valkey 7.2 – 9.x, Dragonfly 1.x) through
/// Keel's own code paths — Test Connection's handshake and detection, the SCAN browser, each core editor's load and
/// guarded save, the console and the bulk delete — and the Redis 5 container refused. Run by
/// `scripts/integration-matrix.py`; each server's failures are reported under its name and don't stop the others.
final class ServerMatrixTests: XCTestCase {
    private var matrix = IntegrationMatrix(servers: [])

    override func setUpWithError() throws { matrix = try IntegrationMatrix.current() }

    /// Runs `body` once per server; a thrown error fails that server only, named in the message.
    private func forEachServer(_ body: (MatrixServer, DataCommandService) async throws -> Void) async {
        for server in matrix.servers {
            let service = DataCommandService(session: MatrixConnections.session(MatrixConnections.tcp(server.port)))
            do { try await body(server, service) } catch { XCTFail("\(server.name): \(error)") }
            await service.session.closeAll()
        }
    }

    private let context = DataContext(profile: MatrixConnections.profile)

    // MARK: - Connect, detect, browse

    func testConnectDetectBrowsePerServer() async {
        await forEachServer { server, service in
            // Test Connection (FR-CN10): handshake, PING, INFO server, detection (INT-02).
            let tested = await ConnectionTester().test(ConnectionSettings(name: server.name, host: IntegrationMatrix.host, port: server.port), password: nil, profileID: nil)
            let identity = try tested.get().identity
            XCTAssertEqual(identity.kind, server.kind, server.name)
            XCTAssertEqual(identity.version, ServerVersion(server.version), "\(server.name) reports \(identity.displayName)")
            XCTAssertEqual(identity.mode, .standalone, server.name)

            // Browse (FR-KB01): SCAN-only paging with the pattern filter finds exactly the keys made here, in a tree.
            let prefix = MatrixConnections.prefix("browse")
            let names = (0..<25).map { "\(prefix)users:\($0)" } + ["\(prefix)orders:1", "\(prefix)plain"]
            for name in names {
                let outcome = try await NewKey.create(Data(name.utf8), .string(Data("v".utf8)), service: service, context: context)
                XCTAssertEqual(outcome, .created, name)
            }
            let index = KeyIndex(service: service, context: context, configuration: KeyIndexConfiguration(pageSize: 10, filter: KeyFilter(pattern: prefix + "*")))
            let status = await index.autoPage()
            XCTAssertEqual(status.phase, .complete, "\(server.name): \(status)")
            let count = await index.count
            let listed = await index.keys(in: 0..<count).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(Set(listed), Set(names), server.name)
            XCTAssertEqual(listed.count, names.count, "\(server.name): SCAN duplicates are dropped")
            // Opening a row reads its header: type, PTTL and length side by side.
            let header = await KeyHeader.load(key: Data(names[0].utf8), type: .string, service: service, context: context)
            XCTAssertEqual(header.length, 1, server.name)
            XCTAssertEqual(header.ttlMilliseconds, nil, "\(server.name): no TTL")
            try await cleanUp(prefix, service)
        }
    }

    // MARK: - Editors

    /// One editor's round trip as the editor shell runs it: create, load, edit the draft, save the binding's writes in
    /// `MULTI/EXEC` under its `WATCH` guard, load again. Returns the rows the server has after the save.
    private func save(_ type: KeyType, key: Data, _ service: DataCommandService, edit: ([EditorRow]) -> [EditorRow]) async throws -> [EditorRow] {
        let binding = try XCTUnwrap(EditorBinding.editor(for: type))
        let loaded = try await binding.load(key, service, context)
        let draft = edit(loaded.rows)
        let writes = binding.writes(key, loaded.rows, draft)
        XCTAssertFalse(writes.isEmpty, "\(type): the edit changes something")
        let result = try await service.executeTransaction(writes, unchanged: binding.saveGuard?(key, loaded.rows, draft) ?? loaded.watch, context: context)
        guard case .array(let replies) = result.reply else { throw IntegrationMatrix.Problem.invalid("\(type): EXEC replied \(result.reply)") }
        XCTAssertFalse(replies.contains { $0.isError }, "\(type): \(replies)")
        return try await binding.load(key, service, context).rows
    }

    private func text(_ rows: [EditorRow]) -> [String: String] {
        Dictionary(rows.map { (String(decoding: $0.id, as: UTF8.self), String(decoding: $0.value, as: UTF8.self)) }, uniquingKeysWith: { a, _ in a })
    }

    func testEditorsPerServer() async {
        await forEachServer { server, service in
            let prefix = MatrixConnections.prefix("editors")
            func key(_ name: String) -> Data { Data((prefix + name).utf8) }
            func create(_ name: String, _ value: NewKey.Value) async throws {
                let outcome = try await NewKey.create(key(name), value, service: service, context: context)
                XCTAssertEqual(outcome, .created, "\(server.name): \(name)")
            }
            func pair(_ field: String, _ value: String) -> DataOperation.FieldValue { DataOperation.FieldValue(field: Data(field.utf8), value: Data(value.utf8)) }

            // String (FR-ED01).
            try await create("string", .string(Data("before".utf8)))
            let string = try await save(.string, key: key("string"), service) { rows in rows.map { EditorRow(id: $0.id, value: Data("after".utf8)) } }
            XCTAssertEqual(string.map(\.value), [Data("after".utf8)], server.name)

            // Hash (FR-ED02): change one field, delete one, add one.
            try await create("hash", .hash([pair("a", "1"), pair("b", "2")]))
            let hash = try await save(.hash, key: key("hash"), service) { rows in
                HashEditor.delete(Data("b".utf8), from: rows.map { $0.id == Data("a".utf8) ? EditorRow(id: $0.id, value: Data("10".utf8)) : $0 })
                    + [EditorRow(id: Data("c".utf8), value: Data("3".utf8))]
            }
            XCTAssertEqual(text(hash), ["a": "10", "c": "3"], server.name)

            // List (FR-ED03): edit an item in place, then a push runs at once under the length guard.
            try await create("list", .list(["x", "y", "z"].map { Data($0.utf8) }))
            let list = try await save(.list, key: key("list"), service) { rows in rows.map { ListEditor.index(of: $0.id) == 1 ? EditorRow(id: $0.id, value: Data("Y".utf8)) : $0 } }
            XCTAssertEqual(list.map { String(decoding: $0.value, as: UTF8.self) }, ["x", "Y", "z"], server.name)
            let push = ListEditor.push(Data("w".utf8), key: key("list"), atHead: false)
            _ = try await service.executeTransaction(push.writes, unchanged: push.watch, context: context)
            let pushed = try await ListEditor.load(key: key("list"), service: service, context: context).rows
            XCTAssertEqual(pushed.map { String(decoding: $0.value, as: UTF8.self) }, ["x", "Y", "z", "w"], server.name)

            // Set (FR-ED04): a removal is saved from the draft; "+ Add member" runs at once.
            try await create("set", .set(["m1", "m2"].map { Data($0.utf8) }))
            let set = try await save(.set, key: key("set"), service) { rows in rows.filter { $0.id != Data("m1".utf8) } }
            XCTAssertEqual(set.map { String(decoding: $0.id, as: UTF8.self) }, ["m2"], server.name)
            let member = try await service.executeTransaction(SetEditor.add(Data("m3".utf8), key: key("set")), unchanged: nil, context: context)
            XCTAssertEqual(SetEditor.addOutcome(member.reply), .added, "\(server.name): \(member.reply)")
            let members = try await SetEditor.load(key: key("set"), service: service, context: context).rows
            XCTAssertEqual(Set(members.map { String(decoding: $0.id, as: UTF8.self) }), ["m2", "m3"], server.name)

            // Sorted set (FR-ED05): a score change reorders; the page read uses ZRANGE BYSCORE or its probed fallback (6.0).
            try await create("zset", .sortedSet([.init(score: 1, member: Data("low".utf8)), .init(score: 2, member: Data("high".utf8))]))
            let zset = try await save(.zset, key: key("zset"), service) { rows in
                rows.map { $0.id == Data("low".utf8) ? SortedSetEditor.row($0.id, score: 5) : $0 }
            }
            XCTAssertEqual(zset.map { String(decoding: $0.id, as: UTF8.self) }, ["high", "low"], server.name)
            XCTAssertEqual(zset.last.flatMap(SortedSetEditor.score), 5, server.name)

            // Stream (FR-ED06): entries are appended with Add entry (XADD *), never edited; the editor lists newest first.
            try await create("stream", .stream(id: StreamEditor.autoID, fields: [pair("event", "created")]))
            let added = try await service.executeTransaction(
                StreamEditor.add(id: StreamEditor.autoID, fields: [pair("event", "paid")], key: key("stream")), unchanged: nil, context: context)
            XCTAssertNotNil(StreamEditor.addedID(added.reply), "\(server.name): \(added.reply)")
            let stream = try await StreamEditor.load(key: key("stream"), service: service, context: context).rows
            XCTAssertEqual(stream.compactMap(StreamEditor.fields).map { $0.map { String(decoding: $0.value, as: UTF8.self) } }, [["paid"], ["created"]], server.name)

            // A guarded save loses to a change made after the load: CONFLICT, and nothing is written (FR-ED10).
            let binding = try XCTUnwrap(EditorBinding.editor(for: .string))
            let stale = try await binding.load(key("string"), service, context)
            _ = try await service.execute(.operation(.stringSet(key: key("string"), value: Data("elsewhere".utf8), keepTTL: true)), origin: .editor, context: context)
            let draft = [EditorRow(id: stale.rows[0].id, value: Data("mine".utf8))]
            do {
                _ = try await service.executeTransaction(binding.writes(key("string"), stale.rows, draft), unchanged: stale.watch, context: context)
                XCTFail("\(server.name): a stale save must conflict")
            } catch let error as DataCommandError { XCTAssertEqual(error, .conflict, server.name) }
            let after = try await binding.load(key("string"), service, context).rows.map(\.value)
            XCTAssertEqual(after, [Data("elsewhere".utf8)], server.name)
            try await cleanUp(prefix, service)
        }
    }

    // MARK: - Console

    func testConsolePerServer() async {
        await forEachServer { server, service in
            let prefix = MatrixConnections.prefix("console")
            let console = ConsoleSession(service: service, profile: MatrixConnections.profile, database: 0, address: "\(IntegrationMatrix.host):\(server.port)")
            func lines(_ outcome: ConsoleOutcome) -> [String] {
                guard case .printed(let lines) = outcome else { return ["unexpected \(outcome)"] }
                return lines.map(\.text)
            }
            /// Runs one console line and checks what it printed.
            func expect(_ arguments: [Data], _ expected: [String], _ message: String = "", confirmation: CommandConfirmation? = nil) async {
                let printed = lines(await console.run(arguments, confirmation: confirmation))
                XCTAssertEqual(printed, expected, "\(server.name) \(message)")
            }
            await expect(words("PING"), ["PONG"])
            await expect(words("SET", prefix + "a", "1"), ["OK"])
            await expect(words("SET", prefix + "b", "2"), ["OK"])
            await expect(words("GET", prefix + "a"), ["\"1\""])
            // An unknown command is sent as typed (after Keel's notice) and the server's error printed.
            let unknown = lines(await console.run(words("NOSUCHCOMMAND")))
            XCTAssertEqual(unknown.last?.hasPrefix("(error) ERR unknown command"), true, "\(server.name): \(unknown)")

            // SELECT is the console's own: its prompt follows, and the browser's database doesn't move.
            await expect(words("SELECT", "1"), ["OK"])
            let prompt = await console.prompt
            XCTAssertEqual(prompt, "\(IntegrationMatrix.host):\(server.port)[1]> ", server.name)
            await expect(words("GET", prefix + "a"), ["(nil)"], "\(server.name): db1 doesn't have db0's key")
            _ = await console.run(words("SELECT", "0"))

            // Multi-key DEL asks for the typed key count first and sends nothing until confirmed (FR-SF04).
            let delete = words("DEL", prefix + "a", prefix + "b")
            guard case .needsConfirmation(let request, _) = await console.run(delete) else { return XCTFail("\(server.name): multi-key DEL must ask first") }
            XCTAssertEqual(request.typedText, "2", server.name)
            await expect(words("EXISTS", prefix + "a", prefix + "b"), ["(integer) 2"], "\(server.name): nothing was deleted yet")
            let confirmation = CommandConfirmation(scope: .keys(Set(delete.dropFirst())), database: 0)
            await expect(delete, ["(integer) 2"], confirmation: confirmation)
            await console.close()
        }
    }

    // MARK: - Bulk delete

    func testBulkDeletePerServer() async {
        await forEachServer { server, service in
            let prefix = MatrixConnections.prefix("bulk")
            let doomed = (0..<120).map { Data("\(prefix)tmp:\($0)".utf8) }, kept = Data("\(prefix)keep".utf8)
            for key in doomed + [kept] { _ = try await NewKey.create(key, .string(Data("v".utf8)), service: service, context: context) }

            let pattern = Data("\(prefix)tmp:*".utf8)
            let job = try BulkDeleteJob(pattern: pattern, throttle: nil, service: service, profile: MatrixConnections.profile, database: 0)
            let sample = await job.sample()
            XCTAssertFalse(sample.keys.isEmpty, "\(server.name): Preview matches finds keys")
            let report = await job.run(confirmation: BulkDeleteJob.confirmation(for: pattern, database: 0))
            await job.close()
            XCTAssertTrue(report.isComplete, "\(server.name): \(report.summary)")
            XCTAssertEqual(report.deleted, doomed.count, server.name)

            // Only the matching keys went; the neighbour outside the pattern stays.
            let remaining = try await service.execute(.raw(words("EXISTS") + doomed + [kept]), origin: .browser, context: context).reply
            XCTAssertEqual(remaining, .integer(1), server.name)
            try await cleanUp(prefix, service)
        }
    }

    // MARK: - ACL

    /// NFR-QA03's restricted ACL user: a user without `@write` connects, detects and browses; a write comes back as the
    /// server's `NOPERM` and changes nothing.
    func testRestrictedACLUserPerServer() async {
        await forEachServer { server, service in
            let user = "keel-matrix-reader", password = "keel-matrix-pw"
            // The fixture user is made over a plain admin connection: setting up the server isn't one of Keel's paths.
            let created = try await admin(server.port, words("ACL", "SETUSER", user, "reset", "on", ">" + password, "~*", "+@all", "-@write"))
            XCTAssertEqual(created, .simpleString(Data("OK".utf8)), "\(server.name): ACL SETUSER")
            let prefix = MatrixConnections.prefix("acl"), key = Data("\(prefix)k".utf8)
            _ = try await NewKey.create(key, .string(Data("original".utf8)), service: service, context: context)

            let settings = ConnectionSettings(name: server.name, host: IntegrationMatrix.host, port: server.port, username: user)
            let tested = await ConnectionTester().test(settings, password: Data(password.utf8), profileID: nil)
            XCTAssertEqual(try tested.get().identity.kind, server.kind, server.name)

            let reader = DataCommandService(session: MatrixConnections.session(MatrixConnections.tcp(server.port), username: user, password: password))
            let index = KeyIndex(service: reader, context: context, configuration: KeyIndexConfiguration(filter: KeyFilter(pattern: prefix + "*")))
            let status = await index.autoPage()
            XCTAssertEqual(status.loadedCount, 1, "\(server.name): \(status)")
            let write = try await reader.execute(.operation(.stringSet(key: key, value: Data("changed".utf8), keepTTL: true)), origin: .editor, context: context).reply
            XCTAssertTrue(write.errorText?.hasPrefix("NOPERM") == true, "\(server.name): \(write)")
            let value = try await service.execute(.operation(.get(key: key)), origin: .editor, context: context).reply
            XCTAssertEqual(value, .bulkString(Data("original".utf8)), server.name)
            await reader.session.closeAll()
            _ = try await admin(server.port, words("ACL", "DELUSER", user))
            try await cleanUp(prefix, service)
        }
    }

    // MARK: - Minimum version

    /// AC2: Redis 5 is refused at detection with `UNSUPPORTED_SERVER`, naming the minimum.
    func testRedis5Refused() async throws {
        let port = try matrix.refusedPort ?? IntegrationMatrix.port("KEEL_INTEGRATION_REFUSED_PORT")
        let result = await ConnectionTester().test(ConnectionSettings(name: "redis-5", host: IntegrationMatrix.host, port: port), password: nil, profileID: nil)
        guard case .failure(let failure) = result else { return XCTFail("Redis 5 connected: \(result)") }
        XCTAssertEqual(failure.category, .unsupportedServer)
        XCTAssertEqual(failure.category.rawValue, "UNSUPPORTED_SERVER")
        XCTAssertTrue(failure.message.contains("6.0") && failure.message.contains("5.0"), failure.message)
    }

    // MARK: - Helpers

    private func admin(_ port: UInt16, _ arguments: [Data]) async throws -> RESPValue {
        let connection = RedisConnection(endpoint: MatrixConnections.tcp(port))
        try await connection.connect()
        defer { Task { await connection.close() } }
        return try await connection.send(arguments)
    }

    /// Removes this test's keys the way the app would: the bulk delete over the prefix.
    private func cleanUp(_ prefix: String, _ service: DataCommandService) async throws {
        let pattern = Data((prefix + "*").utf8)
        let job = try BulkDeleteJob(pattern: pattern, throttle: nil, service: service, profile: MatrixConnections.profile, database: 0)
        let report = await job.run(confirmation: BulkDeleteJob.confirmation(for: pattern, database: 0))
        await job.close()
        if !report.isComplete { throw IntegrationMatrix.Problem.invalid("clean-up: \(report.summary)") }
    }
}

extension RESPValue {
    fileprivate var isError: Bool { errorText != nil }

    fileprivate var errorText: String? {
        switch self {
        case .error(let text), .blobError(let text): return String(decoding: text, as: UTF8.self)
        default: return nil
        }
    }
}

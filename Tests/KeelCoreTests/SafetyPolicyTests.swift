import Foundation
import XCTest

@testable import KeelCore

final class SafetyPolicyTests: XCTestCase {
    private let catalog = CommandCatalog.bundled
    private let readOnly = SafetyProfile(name: "payments-prod", readOnly: true)
    private let writable = SafetyProfile(name: "api-staging", readOnly: false)
    private let allOrigins: [CommandOrigin] = [.editor, .browser, .console, .bulk]

    private func verdict(
        _ arguments: [Data], _ origin: CommandOrigin, _ profile: SafetyProfile, database: Int = 0, confirmation: CommandConfirmation? = nil, catalog: CommandCatalog? = nil
    ) -> SafetyVerdict {
        SafetyPolicy.evaluate(
            arguments, command: (catalog ?? self.catalog).resolve(arguments), origin: origin, profile: profile, database: database, confirmation: confirmation)
    }

    private func words(_ line: String) -> [Data] { line.split(separator: " ").map { Data($0.utf8) } }

    // MARK: - Story tests

    func testReadOnlyBlocksEveryWriteOrigin() {
        let writes = [
            "SET k v", "HSET h f v", "DEL k", "UNLINK a b", "FLUSHDB", "FLUSHALL", "EXPIRE k 10", "RENAME a b", "PUBLISH ch msg", "EVAL return 0", "EVALSHA abc 0",
            "FCALL f 0", "SCRIPT LOAD x", "FUNCTION LOAD x", "CONFIG SET maxmemory 1", "SWAPDB 0 1", "MIGRATE h 6379 k 0 5000", "SORT k STORE dst", "NOSUCHCOMMAND x",
            "CLIENT NOSUCHSUB"
        ]
        for origin in allOrigins {
            for line in writes {
                let result = verdict(words(line), origin, readOnly)
                XCTAssertFalse(result.isAllowed, "\(line) from \(origin)")
                XCTAssertEqual(result.code, "READ_ONLY", "\(line) from \(origin)")
            }
            // Typed editor operations compile to commands and are refused the same way.
            let operations: [DataOperation] = [
                .stringSet(key: Data("k".utf8), value: Data("v".utf8), keepTTL: true), .hashSetField(key: Data("h".utf8), field: Data("f".utf8), value: Data()),
                .listPush(key: Data("l".utf8), values: [Data("x".utf8)], atHead: true), .setAdd(key: Data("s".utf8), members: [Data("m".utf8)]),
                .sortedSetAdd(key: Data("z".utf8), members: [.init(score: 1, member: Data("m".utf8))]),
                .streamAdd(key: Data("x".utf8), id: Data("*".utf8), fields: [.init(field: Data("f".utf8), value: Data("v".utf8))]),
                .rename(key: Data("a".utf8), newKey: Data("b".utf8), overwrite: false), .expire(key: Data("k".utf8), milliseconds: 1000),
                .persist(key: Data("k".utf8)), .delete(keys: [Data("k".utf8)]), .delete(keys: [Data("a".utf8), Data("b".utf8)]), .flushDatabase(async: true),
                .flushAll(async: false)
            ]
            for operation in operations {
                XCTAssertEqual(verdict(operation.arguments, origin, readOnly).code, "READ_ONLY", "\(operation) from \(origin)")
            }
        }
        // Reads still work on a read-only profile, from every origin.
        for origin in allOrigins {
            for line in ["GET k", "SCAN 0 COUNT 100", "HSCAN h 0", "TYPE k", "PTTL k", "XINFO STREAM s", "MEMORY USAGE k", "DBSIZE", "PING", "INFO"] {
                XCTAssertTrue(verdict(words(line), origin, readOnly).isAllowed, "\(line) from \(origin)")
            }
        }
    }

    func testReadOnlyScriptsAllowed() {
        for line in ["EVAL_RO return 0", "EVALSHA_RO abc 0", "FCALL_RO f 0"] {
            XCTAssertEqual(verdict(words(line), .console, readOnly), .allow(.read), line)
        }
        for line in ["EVAL return 0", "EVALSHA abc 0", "FCALL f 0", "SCRIPT FLUSH", "FUNCTION DELETE lib"] {
            XCTAssertEqual(verdict(words(line), .console, readOnly).code, "READ_ONLY", line)
        }
        // On a writable profile only the console runs scripts.
        XCTAssertEqual(verdict(words("EVAL return 0"), .console, writable), .allow(.script))
        for origin in [CommandOrigin.editor, .browser, .bulk] {
            XCTAssertEqual(verdict(words("EVAL return 0"), origin, writable).code, "BLOCKED_COMMAND", "editors never run scripts")
        }
    }

    func testDestructiveNeedsTypedConfirmation() throws {
        let cases: [(String, ConfirmationRequest.Operation, String)] = [
            ("DEL cust:41 cust:42", .deleteKeys(count: 2), "2"), ("UNLINK cust:41 cust:42 cust:43", .deleteKeys(count: 3), "3"), ("FLUSHDB", .flushDatabase(3), "db3"),
            ("FLUSHDB ASYNC", .flushDatabase(3), "db3"), ("FLUSHALL", .flushAll, "api-staging")
        ]
        for (line, operation, typed) in cases {
            let arguments = words(line)
            for origin in allOrigins {
                let result = verdict(arguments, origin, writable, database: 3)
                guard case .confirmationRequired(let request) = result else { return XCTFail("\(line) from \(origin): \(result)") }
                XCTAssertEqual(result.code, "CONFIRMATION_REQUIRED")
                XCTAssertTrue(request.message.hasSuffix("needs a typed confirmation."), request.message)
                XCTAssertEqual(request.operation, operation, line)
                XCTAssertEqual(request.typedText, typed, line)
                XCTAssertFalse(request.message.contains("cust:"), "messages never name keys")

                // The matching confirmation lets it through …
                let good = CommandConfirmation(scope: .command(arguments), database: 3)
                XCTAssertEqual(verdict(arguments, origin, writable, database: 3, confirmation: good), .allow(.destructive), "\(line) from \(origin)")
                // … but not one for another command or another database.
                let otherCommand = CommandConfirmation(scope: .command(words("DEL x y")), database: 3)
                let otherDatabase = CommandConfirmation(scope: .command(arguments), database: 4)
                for bad in [otherCommand, otherDatabase] {
                    XCTAssertFalse(verdict(arguments, origin, writable, database: 3, confirmation: bad).isAllowed, "\(line) from \(origin) with \(bad)")
                }
            }
        }
        // Deleting one key is an ordinary write (the UI asks with a normal confirmation, FR-ED12).
        XCTAssertEqual(verdict(words("UNLINK k"), .editor, writable), .allow(.write))
        XCTAssertEqual(verdict(words("DEL k"), .console, writable), .allow(.write))
    }

    func testUnknownCommandBlockedOnReadOnly() {
        for line in ["NOSUCHCOMMAND", "CLIENT NOSUCHSUB", "client|list", "JSON.SET k $ 1"] {
            for origin in allOrigins {
                XCTAssertFalse(verdict(words(line), origin, readOnly).isAllowed, "\(line) from \(origin)")
            }
            // Writable: the console runs it with a notice; nothing else may.
            XCTAssertEqual(verdict(words(line), .console, writable), .allow(.unknown), line)
            for origin in [CommandOrigin.editor, .browser, .bulk] {
                XCTAssertEqual(verdict(words(line), origin, writable).code, "BLOCKED_COMMAND", "\(line) from \(origin)")
            }
        }
        // A command the server reports with neither flag and no core group (a module) is unknown too.
        let live = catalog.merging(live: CommandCatalog(commands: [CommandInfo(name: "json.set", arity: -4, flags: []), CommandInfo(name: "json.get", arity: -2, flags: [.readonly])]))
        XCTAssertEqual(SafetyPolicy.classify(words("JSON.SET k $ 1"), command: live.resolve(words("JSON.SET k $ 1"))), .unknown)
        XCTAssertEqual(verdict(words("JSON.SET k $ 1"), .console, readOnly, catalog: live).code, "READ_ONLY")
        XCTAssertEqual(verdict(words("JSON.GET k"), .editor, readOnly, catalog: live), .allow(.read))
    }

    // MARK: - Classification

    func testClassificationTable() {
        let table: [(String, SafetyClass)] = [
            ("GET k", .read), ("SORT_RO k", .read), ("EVAL_RO s 0", .read), ("PFCOUNT h", .read), ("XREAD STREAMS s 0", .read), ("SET k v", .write),
            ("BLPOP l 0", .write), ("PUBLISH ch m", .write), ("SPUBLISH ch m", .write), ("DEL k", .write), ("DEL a b", .destructive), ("FLUSHALL ASYNC", .destructive),
            ("EVAL s 0", .script), ("FCALL f 0", .script), ("SCRIPT EXISTS a", .script), ("FUNCTION LIST", .script), ("CONFIG SET a b", .admin),
            ("CONFIG GET a", .admin), ("SHUTDOWN", .admin), ("SWAPDB 0 1", .admin), ("RESTORE k 0 x", .admin), ("SORT k", .admin), ("KEYS *", .keys),
            ("MONITOR", .streaming), ("SUBSCRIBE a", .streaming), ("SSUBSCRIBE a", .streaming), ("SELECT 1", .session), ("MULTI", .session),
            ("EXEC", .session), ("HELLO 3", .session), ("PING", .neutral), ("INFO", .neutral), ("ROLE", .neutral), ("COMMAND DOCS", .neutral),
            ("UNSUBSCRIBE", .streaming), ("CLIENT REPLY OFF", .forbidden), ("NOSUCH", .unknown)
        ]
        for (line, expected) in table {
            XCTAssertEqual(SafetyPolicy.classify(words(line), command: catalog.resolve(words(line))), expected, line)
        }
        XCTAssertEqual(SafetyPolicy.classify([], command: nil), .forbidden)
        XCTAssertFalse(SafetyClass.read.mayWrite)
        XCTAssertFalse(SafetyClass.neutral.mayWrite)
        XCTAssertTrue(SafetyClass.unknown.mayWrite, "unknown fails closed")
        XCTAssertTrue(SafetyClass.script.mayWrite)
    }

    func testConsoleOnlyCommands() {
        // Admin and KEYS: a plain confirmation in the console, refused anywhere else.
        guard case .confirmationRequired(let admin) = verdict(words("CONFIG SET maxmemory 1"), .console, writable) else { return XCTFail() }
        XCTAssertEqual(admin.operation, .admin(command: "CONFIG SET"))
        XCTAssertNil(admin.typedText)
        guard case .confirmationRequired(let keys) = verdict(words("KEYS *"), .console, readOnly) else { return XCTFail("KEYS asks even on read-only") }
        XCTAssertEqual(keys.operation, .keys)
        let yes = CommandConfirmation(scope: .command(words("KEYS *")), database: 0)
        XCTAssertEqual(verdict(words("KEYS *"), .console, readOnly, confirmation: yes), .allow(.keys))
        XCTAssertEqual(verdict(words("CONFIG SET maxmemory 1"), .console, readOnly).code, "READ_ONLY")
        // Streaming and connection state: console only, read-only or not.
        for line in ["MONITOR", "SUBSCRIBE ch", "SELECT 2", "MULTI"] {
            XCTAssertTrue(verdict(words(line), .console, readOnly).isAllowed, line)
            for origin in [CommandOrigin.editor, .browser, .bulk] {
                XCTAssertEqual(verdict(words(line), origin, writable).code, "BLOCKED_COMMAND", "\(line) from \(origin)")
            }
        }
        for line in ["KEYS *", "CONFIG SET a b"] {
            XCTAssertEqual(verdict(words(line), .browser, writable).code, "BLOCKED_COMMAND", "the browser never sends KEYS")
        }
        XCTAssertEqual(verdict(words("CLIENT REPLY OFF"), .console, writable).code, "BLOCKED_COMMAND")
        XCTAssertEqual(verdict([], .console, writable).code, "BLOCKED_COMMAND")
    }

    // MARK: - Batch confirmations

    func testSelectionAndPatternConfirmationsCoverBatches() {
        let selection = CommandConfirmation(scope: .keys([Data("a".utf8), Data("b".utf8), Data("c".utf8)]), database: 0)
        XCTAssertEqual(verdict(words("UNLINK a b"), .browser, writable, confirmation: selection), .allow(.destructive))
        XCTAssertEqual(verdict(words("UNLINK c"), .browser, writable, confirmation: selection), .allow(.write))
        XCTAssertFalse(verdict(words("UNLINK a z"), .browser, writable, confirmation: selection).isAllowed, "z wasn't selected")
        XCTAssertFalse(verdict(words("FLUSHDB"), .browser, writable, confirmation: selection).isAllowed, "a selection never covers a flush")

        let pattern = CommandConfirmation(scope: .pattern(Data("tmp:*".utf8)), database: 0)
        XCTAssertEqual(verdict(words("UNLINK tmp:1 tmp:2"), .bulk, writable, confirmation: pattern), .allow(.destructive))
        XCTAssertFalse(verdict(words("UNLINK tmp:1 user:1"), .bulk, writable, confirmation: pattern).isAllowed)
        XCTAssertFalse(verdict(words("UNLINK tmp:1 tmp:2"), .bulk, writable, database: 1, confirmation: pattern).isAllowed)
        let everything = CommandConfirmation(scope: .pattern(Data("*".utf8)), database: 0)
        XCTAssertFalse(verdict(words("UNLINK a b"), .bulk, writable, confirmation: everything).isAllowed, "pattern * is FLUSHDB's job")
        XCTAssertEqual(verdict(words("UNLINK tmp:1 tmp:2"), .bulk, readOnly, confirmation: pattern).code, "READ_ONLY", "no confirmation beats read-only")
    }

    func testGlobPattern() {
        let table: [(String, String, Bool)] = [
            ("tmp:*", "tmp:1", true), ("tmp:*", "tmp:", true), ("tmp:*", "tmpx", false), ("*", "", true), ("", "", true), ("", "a", false),
            ("a?c", "abc", true), ("a?c", "ac", false), ("h[ae]llo", "hello", true), ("h[ae]llo", "hillo", false), ("h[^e]llo", "hallo", true),
            ("h[^e]llo", "hello", false), ("h[a-c]llo", "hbllo", true), ("h[c-a]llo", "hbllo", true), ("h[a-c]llo", "hdllo", false), ("a\\*b", "a*b", true),
            ("a\\*b", "axb", false), ("*:*:end", "a:b:c:end", true), ("*a*b", "xxaxxbb", true), ("*a*b", "xxaxx", false), ("[\\]]", "]", true)
        ]
        for (pattern, subject, expected) in table {
            XCTAssertEqual(GlobPattern.matches(Data(pattern.utf8), Data(subject.utf8)), expected, "\(pattern) ~ \(subject)")
        }
        // Binary keys match byte for byte.
        XCTAssertTrue(GlobPattern.matches(Data([0x2A]), Data([0xFF, 0x00])))
        XCTAssertFalse(GlobPattern.matches(Data([0xFF, 0x3F]), Data([0xFE, 0x00])))
    }
}

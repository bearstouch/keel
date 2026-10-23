import Foundation
import XCTest

@testable import KeelCore

final class SafetyPolicyReviewTests: XCTestCase {
    private let writable = SafetyProfile(name: "api-staging", readOnly: false)

    private func verdict(_ line: String, _ origin: CommandOrigin, catalog: CommandCatalog = .bundled) -> SafetyVerdict {
        let arguments = line.split(separator: " ").map { Data($0.utf8) }
        return SafetyPolicy.evaluate(arguments, command: catalog.resolve(arguments), origin: origin, profile: writable, database: 0, confirmation: nil)
    }

    /// `UNSUBSCRIBE a b` answers once per channel: on a shared connection the extra replies would be taken as the
    /// next commands' replies, so the unsubscribe family is console-only, on the stream connection.
    func testUnsubscribeFamilyIsConsoleStreamingOnly() {
        for line in ["UNSUBSCRIBE a b", "PUNSUBSCRIBE a:* b:*", "SUNSUBSCRIBE a b", "unsubscribe"] {
            XCTAssertEqual(verdict(line, .console), .allow(.streaming), line)
            for origin in [CommandOrigin.editor, .browser, .bulk] {
                XCTAssertEqual(verdict(line, origin).code, "BLOCKED_COMMAND", "\(line) from \(origin)")
            }
        }
    }

    /// The admin set of 02 Architecture → Safety policy asks in the console and is refused from every other origin,
    /// even with a confirmation that covers it byte for byte.
    func testAdminAndStreamingStayConsoleOnlyWhateverTheConfirmation() {
        let lines = [
            "CONFIG SET maxmemory 1", "SHUTDOWN", "DEBUG SLEEP 0", "REPLICAOF NO ONE", "FAILOVER", "CLUSTER RESET", "ACL SETUSER u", "ACL DELUSER u",
            "MIGRATE h 6379 k 0 5000", "SWAPDB 0 1", "MODULE LOAD x", "CLIENT KILL ID 1", "KEYS *", "MONITOR", "PSUBSCRIBE ch*"
        ]
        for line in lines {
            let arguments = line.split(separator: " ").map { Data($0.utf8) }
            let command = CommandCatalog.bundled.resolve(arguments)
            let yes = CommandConfirmation(scope: .command(arguments), database: 0)
            XCTAssertNotEqual(verdict(line, .console).code, "BLOCKED_COMMAND", line)
            for origin in [CommandOrigin.editor, .browser, .bulk] {
                let result = SafetyPolicy.evaluate(arguments, command: command, origin: origin, profile: writable, database: 0, confirmation: yes)
                XCTAssertEqual(result.code, "BLOCKED_COMMAND", "\(line) from \(origin)")
            }
        }
    }

    /// A server may flag a scripting command `admin` (restrictive flags only add); admin wins, so it needs the console's confirmation.
    func testServerFlaggedAdminScriptingCommandStaysAdmin() throws {
        let bundled = CommandCatalog.bundled
        var flush = try XCTUnwrap(bundled.command(named: "script|flush"))
        flush.flags.insert(.admin)
        flush.docs = nil
        let merged = bundled.merging(live: CommandCatalog(commands: [flush]))
        XCTAssertEqual(SafetyPolicy.classify([Data("SCRIPT".utf8), Data("FLUSH".utf8)], command: merged.resolve([Data("SCRIPT".utf8), Data("FLUSH".utf8)])), .admin)
        XCTAssertEqual(verdict("SCRIPT FLUSH", .console, catalog: merged).code, "CONFIRMATION_REQUIRED")
        XCTAssertEqual(verdict("SCRIPT FLUSH", .editor, catalog: merged).code, "BLOCKED_COMMAND")
        XCTAssertEqual(verdict("SCRIPT FLUSH", .console), .allow(.script), "bundled SCRIPT FLUSH is still a script")
    }
}

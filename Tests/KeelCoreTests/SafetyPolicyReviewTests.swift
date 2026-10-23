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
            for origin in [CommandOrigin.editor, .browser, .bulk, .agent(grantID: UUID())] {
                XCTAssertEqual(verdict(line, origin).code, "BLOCKED_COMMAND", "\(line) from \(origin)")
            }
        }
    }

    /// A server may flag a scripting command `admin` (restrictive flags only add); admin wins, so agents never get it.
    func testServerFlaggedAdminScriptingCommandStaysAdmin() throws {
        let bundled = CommandCatalog.bundled
        var flush = try XCTUnwrap(bundled.command(named: "script|flush"))
        flush.flags.insert(.admin)
        flush.docs = nil
        let merged = bundled.merging(live: CommandCatalog(commands: [flush]))
        XCTAssertEqual(SafetyPolicy.classify([Data("SCRIPT".utf8), Data("FLUSH".utf8)], command: merged.resolve([Data("SCRIPT".utf8), Data("FLUSH".utf8)])), .admin)
        XCTAssertEqual(verdict("SCRIPT FLUSH", .agent(grantID: UUID()), catalog: merged).code, "BLOCKED_COMMAND")
        XCTAssertEqual(verdict("SCRIPT FLUSH", .agent(grantID: UUID())), .allow(.script), "bundled SCRIPT FLUSH is still a script")
    }
}

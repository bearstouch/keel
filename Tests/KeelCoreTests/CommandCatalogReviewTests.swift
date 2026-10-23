import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Review-driven cases for KEEL-012.
final class CommandCatalogReviewTests: XCTestCase {
    private let catalog = CommandCatalog.bundled

    private static func args(_ words: String...) -> [Data] { words.map { Data($0.utf8) } }

    /// A live server adding `readonly` to a bundled non-read (scripts, pub/sub, admin) must not make it a read; a
    /// live-only command keeps the server's word, and dropping `readonly` only makes a command stricter.
    func testLiveReadonlyCannotRelaxBundledCommand() {
        let live = CommandCatalog(commands: [
            CommandInfo(name: "eval", arity: -3, flags: [.readonly]), CommandInfo(name: "publish", arity: 3, flags: [.readonly]),
            CommandInfo(name: "config|set", arity: -4, flags: [.readonly]), CommandInfo(name: "get", arity: 2, flags: []),
            CommandInfo(name: "eval_ro", arity: -3, flags: [.readonly]), CommandInfo(name: "json.get", arity: -2, flags: [.readonly])
        ])
        let merged = catalog.merging(live: live)
        XCTAssertEqual(merged.access(of: Self.args("EVAL", "return 1", "0")), .other)
        XCTAssertEqual(merged.access(of: Self.args("PUBLISH", "c", "m")), .other)
        XCTAssertEqual(merged.resolve(Self.args("CONFIG", "SET", "x", "y"))?.flags, [.admin, .dangerous])
        XCTAssertEqual(merged.access(of: Self.args("GET", "k")), .other, "dropping readonly is stricter, so it's kept")
        XCTAssertEqual(merged.access(of: Self.args("EVAL_RO", "return 1", "0")), .read)
        XCTAssertEqual(merged.access(of: Self.args("JSON.GET", "k")), .read)
    }

    /// Arity and key ranges come from the server; extreme values must not trap.
    func testExtremeLiveNumbersDoNotTrap() {
        let reply = RESPValue.array([
            .array([.bulkString(Data("odd".utf8)), .integer(.min), .array([]), .integer(.max), .integer(.min), .integer(.max)]),
            .array([.bulkString(Data("odd2".utf8)), .integer(.max), .array([]), .integer(1), .integer(.min), .integer(1)])
        ])
        let live = CommandCatalog.live(commandReply: reply)
        let odd = live?.command(named: "odd"), odd2 = live?.command(named: "odd2")
        XCTAssertEqual(odd?.acceptsArgumentCount(3), false)
        XCTAssertEqual(odd?.acceptsArgumentCount(-1), false)
        XCTAssertEqual(odd?.keyIndexes(argumentCount: 3), [])
        XCTAssertEqual(odd2?.acceptsArgumentCount(3), false)
        XCTAssertEqual(odd2?.keyIndexes(argumentCount: 3), [])
        XCTAssertEqual(CommandInfo(name: "x", arity: -2, flags: []).acceptsArgumentCount(-5), false)
    }
}

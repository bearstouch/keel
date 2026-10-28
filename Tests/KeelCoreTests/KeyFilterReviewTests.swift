import Foundation
import XCTest

@testable import KeelCore

final class KeyFilterReviewTests: XCTestCase {
    /// A page far larger than the TYPE window is checked in full, never with more than the window in flight.
    func testClientSideTypeChecksAreBoundedAndComplete() async {
        let keys = (0..<600).map { ("k:\($0)", $0.isMultiple(of: 3) ? "ReJSON-RL" : "hash") }
        let fake = TypedKeyspace(pages: [keys])
        let index = fake.index(KeyFilter(type: .other))
        let status = await index.loadMore()
        XCTAssertEqual(status.phase, .complete)
        let count = await index.count
        XCTAssertEqual(count, 200)
        XCTAssertEqual(fake.commands.filter { $0.first == "TYPE" }.count, 600)
    }

    /// The first failed TYPE stops further checks, and the page reports that failure rather than the unsent keys.
    func testFailedTypeCheckStopsSendingAndReportsTheFailure() async {
        let keys = (0..<600).map { ("k:\($0)", "hash") }
        let fake = TypedKeyspace(pages: [keys], typeError: "NOPERM this user has no permissions to run the 'type' command")
        let index = fake.index(KeyFilter(type: .other))
        let status = await index.loadMore()
        guard case .failed(let error) = status.phase else { return XCTFail("\(status.phase)") }
        XCTAssertEqual(error.code, "PERMISSION_DENIED")
        XCTAssertLessThanOrEqual(fake.commands.filter { $0.first == "TYPE" }.count, KeyIndex.typeCheckWindow)
    }

    func testRestartBumpsTheGeneration() async {
        let index = TypedKeyspace(pages: []).index()
        let before = await index.generation
        await index.restart()
        let after = await index.generation
        XCTAssertEqual(after, before + 1)
    }

    /// The glob help says what Redis's `stringmatchlen` (and `GlobPattern`, which bulk delete checks keys with) does:
    /// each entry's syntax matches the subjects its meaning promises and none it rules out.
    func testGlobHelpAgreesWithGlobPattern() {
        let examples: [String: (matches: [String], rejects: [String])] = [
            "*": (["", "a", "user:1"], []),
            "?": (["a", "!"], ["", "ab"]),
            "[abc]": (["a", "b", "c"], ["d", "ab", ""]),
            "[^a]": (["b", "!", "z"], ["a", ""]),
            "[a-z]": (["a", "m", "z"], ["A", "0", "aa"]),
            "\\*": (["*"], ["a", "\\*", ""])
        ]
        XCTAssertEqual(Set(KeyFilter.globHelp.map(\.syntax)), Set(examples.keys), "every help entry has examples")
        for (syntax, cases) in examples {
            for subject in cases.matches { XCTAssertTrue(GlobPattern.matches(Data(syntax.utf8), Data(subject.utf8)), "\(syntax) should match \(subject)") }
            for subject in cases.rejects { XCTAssertFalse(GlobPattern.matches(Data(syntax.utf8), Data(subject.utf8)), "\(syntax) should not match \(subject)") }
        }
        // `!` doesn't negate: `session:[!a]*` keeps exactly the session:a… keys, so the help never offers it.
        XCTAssertTrue(GlobPattern.matches(Data("session:[!a]*".utf8), Data("session:abc".utf8)))
        XCTAssertFalse(GlobPattern.matches(Data("session:[!a]*".utf8), Data("session:xyz".utf8)))
        XCTAssertFalse(KeyFilter.globHelp.contains { $0.syntax.contains("[!") || $0.meaning.contains("[!") })
    }
}

import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// Edge cases of the hash editor (KEEL-030) beyond the story's list.
final class HashEditorReviewTests: XCTestCase {
    private let key = Data("h".utf8)
    private func d(_ text: String) -> Data { Data(text.utf8) }
    private func row(_ field: String, _ value: String) -> EditorRow { EditorRow(id: d(field), value: d(value)) }

    func testHashesHaveAnEditor() {
        XCTAssertNotNil(EditorBinding.editor(for: .hash))
    }

    /// `HGETALL` over RESP3 is a map; RESP2 a flat array. Anything else (an odd count, a non-string) is refused.
    func testFieldsFromArrayAndMap() {
        let flat = RESPValue.array([.bulkString(d("a")), .bulkString(d("1"))])
        XCTAssertEqual(HashEditor.fields(flat), [row("a", "1")])
        XCTAssertEqual(HashEditor.fields(.map([RESPPair(.bulkString(d("a")), .bulkString(d("1")))])), [row("a", "1")])
        XCTAssertNil(HashEditor.fields(.array([.bulkString(d("a"))])))
        XCTAssertNil(HashEditor.fields(.array([.bulkString(d("a")), .integer(1)])))
    }

    func testEditsRefuseEmptyNamesAndMissingFields() {
        let draft = [row("a", "1")]
        XCTAssertEqual(HashEditor.add(field: Data(), value: d("x"), to: draft, overwrite: false), .refused(HashEditor.emptyName))
        XCTAssertEqual(HashEditor.rename(d("a"), to: Data(), in: draft, overwrite: false), .refused(HashEditor.emptyName))
        guard case .refused = HashEditor.rename(d("zz"), to: d("b"), in: draft, overwrite: false) else { return XCTFail("refused") }
        XCTAssertEqual(HashEditor.rename(d("a"), to: d("a"), in: draft, overwrite: false), .applied(draft), "same name: nothing to do")
        XCTAssertEqual(HashEditor.delete(d("a"), from: draft), [])
    }

    /// Only touched fields are written and guarded; an unchanged draft writes nothing.
    func testWritesAndGuardCoverOnlyTouchedFields() {
        let loaded = [row("a", "1"), row("b", "2"), row("c", "3")]
        let draft = [row("a", "1"), row("b", "20"), row("d", "4")]
        XCTAssertEqual(
            HashEditor.writes(key: key, loaded: loaded, draft: draft),
            [.hashSetField(key: key, field: d("b"), value: d("20")), .hashSetField(key: key, field: d("d"), value: d("4")), .hashDeleteFields(key: key, fields: [d("c")])])
        let guardReads = HashEditor.saveGuard(key: key, loaded: loaded, draft: draft)
        XCTAssertEqual(guardReads.reads.map(\.arguments).map { $0.last }, [d("b"), d("c"), d("d")])
        XCTAssertEqual(guardReads.expected, [.bulkString(d("2")), .bulkString(d("3")), .nullBulkString])
        XCTAssertTrue(HashEditor.writes(key: key, loaded: loaded, draft: loaded).isEmpty)
    }

    /// A guard expecting an absent field accepts RESP3's null as well as RESP2's nil bulk string.
    func testGuardTreatsEveryNullAsAbsent() async throws {
        let server = HashServer([("a", "1")])
        server.resp3Null = true
        let draft = [row("a", "1"), row("new", "2")], loaded = [row("a", "1")]
        _ = try await server.service().executeTransaction(
            HashEditor.writes(key: key, loaded: loaded, draft: draft), unchanged: HashEditor.saveGuard(key: key, loaded: loaded, draft: draft),
            context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
        XCTAssertEqual(server.hash, ["a": "1", "new": "2"])
    }

    /// A missing key (no fields) and a key of another type fail the load with a message instead of an empty table.
    func testMissingOrWrongTypeKeyFailsLoad() async {
        let context = DataContext(profile: SafetyProfile(name: "local", readOnly: false))
        let missing = RecordingServer { _ in ":0\r\n" }
        do {
            _ = try await HashEditor.load(key: key, service: DataCommandService(session: missing.session()), context: context)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error, .invalidRequest("The key no longer exists.")) }
        let wrong = RecordingServer { _ in "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n" }
        do {
            _ = try await HashEditor.load(key: key, service: DataCommandService(session: wrong.session()), context: context)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
    }

    /// A large hash deleted between `HLEN` and the first `HSCAN` (which answers a missing key with an empty, complete
    /// scan) fails the load instead of opening an empty hash whose "+ Add field" would recreate the key.
    func testLargeHashDeletedBeforeFirstScanFailsLoad() async {
        let server = RecordingServer { arguments in arguments.first?.uppercased() == "HLEN" ? ":2000\r\n" : "*2\r\n$1\r\n0\r\n*0\r\n" }
        do {
            _ = try await HashEditor.load(key: key, service: DataCommandService(session: server.session()), context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
            XCTFail("expected the key to be gone")
        } catch { XCTAssertEqual(error, EditorReads.gone) }
    }

    /// After a save only the touched fields are re-read; the pages loaded and the cursor stay.
    func testRereadKeepsPages() async throws {
        let server = RecordingServer { arguments in
            switch arguments.last {
            case "b": return "$2\r\n20\r\n"
            default: return "$-1\r\n"
            }
        }
        let loaded = LoadedValue(rows: [row("a", "1"), row("b", "2"), row("c", "3")], watch: WatchGuard(key: key, reads: [], expected: []), next: d("77"))
        let value = try await HashEditor.reread(
            key: key, loaded: loaded, draft: [row("a", "1"), row("b", "20"), row("d", "4")], service: DataCommandService(session: server.session()),
            context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
        XCTAssertEqual(value.rows, [row("a", "1"), row("b", "20")], "c deleted, d not written: both absent on the server")
        XCTAssertEqual(value.next, d("77"))
    }
}

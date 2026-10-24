import Foundation
import XCTest

@testable import KeelCore

final class ValueExportTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testBinaryExportIsByteExact() throws {
        // AC3: every byte value, invalid UTF-8 included, round-trips through the file unchanged.
        let bytes = Data((0...255).map { UInt8($0) } + [0xff, 0xfe, 0x00, 0x0d, 0x0a])
        let exported = try XCTUnwrap(ValueExport.data(key: data("blob"), type: .string, rows: [EditorRow(id: Data(), value: bytes)]))
        XCTAssertEqual(exported, bytes)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keel-export-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try ValueExport.write(exported, to: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(ValueExport.suggestedFileName(key: data("cache:blob"), type: .string, rows: [EditorRow(id: Data(), value: bytes)]), "blob.bin")
    }

    func testCollectionsExportJSONWithoutLosingBytes() throws {
        let binary = Data([0xff, 0x00, 0x61])
        let hash = try XCTUnwrap(
            ValueExport.data(key: data("user:1"), type: .hash, rows: [EditorRow(id: data("name"), value: data("Ada")), EditorRow(id: binary, value: data("x"))]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: hash) as? [String: Any])
        XCTAssertEqual(object["key"] as? String, "user:1")
        XCTAssertEqual(object["type"] as? String, "hash")
        let fields = try XCTUnwrap(object["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["field"] as? String, "name")
        XCTAssertEqual((fields.last?["field"] as? [String: String])?["base64"], binary.base64EncodedString())

        // Lists export head to tail; sorted set scores are numbers, infinities strings.
        let list = try XCTUnwrap(ValueExport.data(key: data("l"), type: .list, rows: [EditorRow(id: data("1"), value: data("b")), EditorRow(id: data("0"), value: data("a"))]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: list) as? [String: Any])?["items"] as? [String], ["a", "b"])
        let zset = try XCTUnwrap(
            ValueExport.data(key: data("z"), type: .zset, rows: [SortedSetEditor.row(data("a"), score: 1.5), SortedSetEditor.row(data("b"), score: -.infinity)]))
        let members = try XCTUnwrap((try JSONSerialization.jsonObject(with: zset) as? [String: Any])?["members"] as? [[String: Any]])
        XCTAssertEqual(members.first?["score"] as? Double, 1.5)
        XCTAssertEqual(members.last?["score"] as? String, "-inf")

        let stream = try XCTUnwrap(
            ValueExport.data(key: data("s"), type: .stream, rows: [StreamEditor.row(data("1-0"), fields: [DataOperation.FieldValue(field: data("f"), value: data("v"))])]))
        let entries = try XCTUnwrap((try JSONSerialization.jsonObject(with: stream) as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["id"] as? String, "1-0")
        XCTAssertEqual((entries.first?["fields"] as? [[String: String]])?.first, ["field": "f", "value": "v"])
        XCTAssertNil(ValueExport.data(key: data("m"), type: .other, rows: []))
    }

    func testCopyTextAndFileNames() {
        let text = [EditorRow(id: Data(), value: data("héllo"))]
        XCTAssertEqual(ValueExport.copyText(key: data("k"), type: .string, rows: text), "héllo")
        // Binary strings copy as the redis-cli argument that parses back to the same bytes.
        XCTAssertEqual(ValueExport.copyText(key: data("k"), type: .string, rows: [EditorRow(id: Data(), value: Data([0xff, 0x41]))]), "\"\\xffA\"")
        XCTAssertEqual(ValueExport.suggestedFileName(key: data("app:users/42"), type: .hash, rows: []), "users_42.json")
        XCTAssertEqual(ValueExport.suggestedFileName(key: data("note"), type: .string, rows: text), "note.txt")
        XCTAssertEqual(ValueExport.suggestedFileName(key: data(".."), type: .set, rows: []), "value.json")
    }
}

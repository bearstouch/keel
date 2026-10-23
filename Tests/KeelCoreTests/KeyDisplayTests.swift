import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class KeyDisplayTests: XCTestCase {
    // MARK: - Story tests

    func testEscapesNonUTF8LikeRedisCli() {
        let key = Data([0xFF, 0x00, 0x61])
        XCTAssertEqual(KeyDisplay.name(key), #"\xff\x00a"#)
        XCTAssertEqual(KeyDisplay.redisCliArgument(key), #""\xff\x00a""#)
        // sdscatrepr's escapes: backslash, quote, \n \r \t \a \b, other bytes as lowercase \xNN.
        let mixed = Data([0x5C, 0x22, 0x0A, 0x0D, 0x09, 0x07, 0x08, 0x7F, 0x80, 0x20, 0x7E, 0xC3])
        XCTAssertEqual(KeyDisplay.name(mixed), #"\\\"\n\r\t\a\b\x7f\x80 ~\xc3"#)
    }

    // MARK: - Extras

    func testValidUTF8ShownAsIs() {
        for text in ["user:1", "caf\u{e9}:\u{1F600}", "a\\b \"q\"", "", "family:\u{1F468}\u{200D}\u{1F469}"] {
            XCTAssertEqual(KeyDisplay.name(Data(text.utf8)), text)
        }
        // The copied argument always escapes, so it parses back to the same bytes.
        XCTAssertEqual(KeyDisplay.redisCliArgument(Data("caf\u{e9} x".utf8)), #""caf\xc3\xa9 x""#)
    }

    func testControlAndBidiCharactersAreEscaped() {
        XCTAssertEqual(KeyDisplay.name(Data("a\nb".utf8)), #"a\nb"#)
        XCTAssertEqual(KeyDisplay.name(Data("a\u{85}".utf8)), #"a\xc2\x85"#)
        XCTAssertEqual(KeyDisplay.name(Data("x\u{202E}gpj.exe".utf8)), #"x\xe2\x80\xaegpj.exe"#)
        XCTAssertEqual(KeyDisplay.name(Data("x\u{2066}y".utf8)), #"x\xe2\x81\xa6y"#)
    }

    /// AC3: a binary key shows escaped in the tree, and opening, renaming and deleting send its original bytes.
    func testBinaryKeyActionsUseOriginalBytes() async throws {
        let binary = Data([0xFF, 0x00, 0x61])
        let server = RecordingServer { arguments in arguments.first == "GET" ? "$1\r\nv\r\n" : arguments.first == "DEL" ? ":1\r\n" : "+OK\r\n" }
        let context = DataContext(profile: SafetyProfile(name: "dev", readOnly: false))
        let service = DataCommandService(session: server.session())
        let index = KeyIndex(service: service, context: context)
        await index.ingest([binary, Data("a:\u{0}".utf8)])

        let rootRows = await rows(index)
        XCTAssertEqual(rootRows, ["a/ (1)", #"\xff\x00a"#])
        let children = await index.namespaceChildren()
        guard case .key(let row) = children[1] else { return XCTFail("\(children)") }
        let key = await index.key(at: row)
        XCTAssertEqual(key, binary)

        _ = try await service.execute(.operation(.get(key: key)), origin: .editor, context: context)
        _ = try await service.execute(.operation(.rename(key: key, newKey: key + Data("2".utf8), overwrite: false)), origin: .editor, context: context)
        _ = try await service.execute(.operation(.delete(keys: [key + Data("2".utf8)])), origin: .editor, context: context)

        let frames = server.opened.flatMap { $0.transport.sent }.map { frame -> [Data] in
            var parser = RESPParser()
            parser.append(frame)
            guard case .array(let items)? = try? parser.next() else { return [] }
            return items.compactMap { if case .bulkString(let bytes) = $0 { bytes } else { nil } }
        }
        let renamed = binary + Data("2".utf8)
        let expected: [[Data]] = [[Data("GET".utf8), binary], [Data("RENAMENX".utf8), binary, renamed], [Data("UNLINK".utf8), renamed]]
        XCTAssertEqual(Array(frames.suffix(3)), expected)
    }
}

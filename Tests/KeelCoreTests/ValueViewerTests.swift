import Foundation
import XCTest

@testable import KeelCore

final class ValueViewerTests: XCTestCase {
    // MARK: - Story tests

    func testJSONAutoDetection() {
        XCTAssertEqual(ValueViewerState(bytes: Data(#" {"theme":"dark","beta":true}"#.utf8), mode: nil).mode, .json)
        XCTAssertEqual(ValueViewerState(bytes: Data("[1, 2]".utf8), mode: nil).mode, .json)
        // Scalars parse as JSON but read better as text; broken JSON and plain text stay Text.
        for text in ["42", #""x""#, "true", #"{"a":}"#, "hello", ""] {
            XCTAssertEqual(ValueViewerState(bytes: Data(text.utf8), mode: nil).mode, .text, text)
        }
        // A remembered choice wins over detection.
        XCTAssertEqual(ValueViewerState(bytes: Data("[1]".utf8), mode: .hex).mode, .hex)

        let state = ValueViewerState(bytes: Data(#"{"theme":"dark","digest":"weekly","beta":true,"n":[1.5e3,null,{}]}"#.utf8), mode: nil)
        XCTAssertTrue(state.isValidJSON)
        XCTAssertNil(state.saveBlock)
        // Keys in their order, numbers as written, two-space indent.
        XCTAssertEqual(
            state.text,
            """
            {
              "theme": "dark",
              "digest": "weekly",
              "beta": true,
              "n": [
                1.5e3,
                null,
                {}
              ]
            }
            """)
        let colored = state.jsonSpans.map { (($0.kind), (state.text as NSString).substring(with: NSRange(location: $0.location, length: $0.length))) }
        XCTAssertEqual(colored.first?.0, .key)
        XCTAssertEqual(colored.first?.1, #""theme""#)
        XCTAssertEqual(colored[1].0, .string)
        XCTAssertEqual(colored[1].1, #""dark""#)
        XCTAssertTrue(colored.contains { $0.0 == .literal && $0.1 == "1.5e3" })
        XCTAssertTrue(colored.contains { $0.0 == .literal && $0.1 == "null" })
    }

    func testJSONErrorLocation() {
        let broken = Data("{\n  \"a\": 1,\n  \"b\" 2\n}".utf8)
        XCTAssertEqual(ValueJSON.validate(broken), JSONSyntaxError(line: 3, column: 7, message: "Expected “:” after the key."))
        // Columns count characters, not bytes.
        XCTAssertEqual(ValueJSON.validate(Data(#"["é", x]"#.utf8))?.column, 7)
        XCTAssertEqual(ValueJSON.validate(Data(#"{"a":1,}"#.utf8))?.message, "Expected a string key.")
        XCTAssertEqual(ValueJSON.validate(Data(#"[1 2]"#.utf8))?.message, "Expected “,” or “]”.")
        XCTAssertEqual(ValueJSON.validate(Data(#"{"a":1} x"#.utf8)), JSONSyntaxError(line: 1, column: 9, message: "Unexpected text after the JSON value."))
        XCTAssertEqual(ValueJSON.validate(Data(#"["abc"#.utf8)), JSONSyntaxError(line: 1, column: 2, message: "The string isn't closed."))

        // AC2: the JSON view shows the error and refuses to save; Text view may save the same bytes.
        var state = ValueViewerState(bytes: Data(#"{"a":1}"#.utf8), mode: .json)
        XCTAssertNotNil(state.edit("{\n  \"a\": 1,\n}"))
        XCTAssertEqual(state.jsonError?.line, 3)
        XCTAssertEqual(state.jsonError?.column, 1)
        XCTAssertFalse(state.isValidJSON)
        XCTAssertNotNil(state.saveBlock)
        XCTAssertEqual(state.jsonError?.description, "Line 3, column 1: Expected a string key.")
        state.show(.text)
        XCTAssertNil(state.saveBlock)
        XCTAssertEqual(state.bytes, Data("{\n  \"a\": 1,\n}".utf8))
        // Opening invalid JSON in JSON view shows its text with the error.
        let opened = ValueViewerState(bytes: Data("{oops".utf8), mode: .json)
        XCTAssertEqual(opened.text, "{oops")
        XCTAssertEqual(opened.jsonError?.column, 2)
    }

    func testHexLayout() {
        let value = Data("Hello, world!\n\u{0}\u{7F}é".utf8)  // 18 bytes
        XCTAssertEqual(HexLayout.lineCount(value.count), 2)
        XCTAssertEqual(HexLayout.lineCount(0), 0)
        XCTAssertEqual(HexLayout.lineCount(16), 1)
        let first = HexLayout.line(0, of: value)
        XCTAssertEqual(first.offset, "00000000")
        XCTAssertEqual(first.hex, "48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 0a 00 7f")
        XCTAssertEqual(first.ascii, "Hello, world!...")
        let last = HexLayout.line(1, of: value)
        XCTAssertEqual(last.offset, "00000010")
        // Padded to the full width, so the ASCII column lines up with full lines.
        XCTAssertEqual(last.hex, "c3 a9" + String(repeating: " ", count: first.hex.count - 5))
        XCTAssertEqual(last.ascii, "..")
        // A slice of a larger buffer reads from its own start.
        let slice = Data([0xAA, 0x41, 0x42])[1...]
        XCTAssertEqual(HexLayout.line(0, of: slice).ascii, "AB")

        // AC3: a 1 MiB value opens in Hex without rendering anything up front; any line is cheap.
        let mebibyte = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let state = ValueViewerState(bytes: mebibyte, mode: .hex)
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(HexLayout.lineCount(state.bytes.count), 65_536)
        XCTAssertEqual(HexLayout.line(65_535, of: mebibyte).offset, "000ffff0")
        XCTAssertEqual(HexLayout.line(65_535, of: mebibyte).hex, "f0 f1 f2 f3 f4 f5 f6 f7  f8 f9 fa fb fc fd fe ff")
    }

    func testRawEscapingMatchesRedisCli() {
        // What `redis-cli GET k` prints for these values (sdscatrepr).
        XCTAssertEqual(ValueRaw.render(Data([0xFF, 0x00, 0x61])), #""\xff\x00a""#)
        XCTAssertEqual(ValueRaw.render(Data("say \"hi\"\\\n\r\t\u{7}\u{8}".utf8)), #""say \"hi\"\\\n\r\t\a\b""#)
        XCTAssertEqual(ValueRaw.render(Data("café".utf8)), #""caf\xc3\xa9""#)
        XCTAssertEqual(ValueRaw.render(Data()), #""""#)
        // Parsing follows redis-cli's quoted arguments: \xNN, the control escapes, and \c for any other c.
        XCTAssertEqual(try ValueRaw.parse(#" "a\x41\n\q\"" "#).get(), Data("aA\nq\"".utf8))
        XCTAssertEqual(try ValueRaw.parse(#""\xZZ""#).get(), Data("xZZ".utf8))
        XCTAssertEqual(try ValueRaw.parse(#""é""#).get(), Data("é".utf8))
        XCTAssertThrowsError(try ValueRaw.parse("abc").get())
        XCTAssertThrowsError(try ValueRaw.parse(#""abc"#).get())
        XCTAssertThrowsError(try ValueRaw.parse(#""a" b"#).get())
        XCTAssertThrowsError(try ValueRaw.parse(#""a\""#).get())
    }

    func testTextEscapesInvalidUTF8() {
        XCTAssertTrue(ValueText.render(Data("plain \\ text\n\tcafé".utf8)) == ("plain \\ text\n\tcafé", false))
        // Invalid bytes force the escaped form, where backslashes double so nothing is ambiguous.
        XCTAssertTrue(ValueText.render(Data([0x61, 0xFF, 0x5C, 0x62, 0xC3, 0xA9])) == (#"a\xff\\bé"#, true))
        // Controls other than tab and newline escape too; truncated, overlong and surrogate sequences are invalid.
        XCTAssertTrue(ValueText.render(Data("a\r\n\u{0}".utf8)) == ("a\\x0d\n\\x00", true))
        XCTAssertEqual(ValueText.render(Data([0xC3])).text, #"\xc3"#)
        XCTAssertEqual(ValueText.render(Data([0xC0, 0x80])).text, #"\xc0\x80"#)
        XCTAssertEqual(ValueText.render(Data([0xED, 0xA0, 0x80])).text, #"\xed\xa0\x80"#)
        XCTAssertEqual(ValueText.render(Data([0xF0, 0x9F, 0x98, 0x80, 0xFF])).text, "😀\\xff")
        // Half-typed escapes stay literal.
        XCTAssertEqual(ValueText.bytes(#"\x4\q\"#, escaped: true), Data(#"\x4\q\"#.utf8))
        XCTAssertEqual(ValueText.bytes(#"\x41"#, escaped: false), Data(#"\x41"#.utf8))
    }

    func testRoundTripBinaryEdit() {
        // AC1: every byte value, plus text with backslashes and look-alike escapes, survives view and edit.
        let samples = [
            Data((0...255).map { UInt8($0) }),
            Data([0xFF, 0x5C, 0x78, 0x34, 0x31, 0x0D, 0x0A, 0x00]),
            Data("\\x41 is not A".utf8) + Data([0x80]),
            Data("plain".utf8),
            Data()
        ]
        for value in samples {
            for mode in [ValueViewMode.text, .raw, .json] {
                var state = ValueViewerState(bytes: value, mode: mode)
                // Opening and re-submitting the same text changes nothing.
                XCTAssertNil(state.edit(state.text), "\(mode) \(value as NSData)")
                XCTAssertEqual(state.bytes, value)
            }
            var text = ValueViewerState(bytes: value, mode: .text)
            XCTAssertEqual(text.edit(text.text + "!"), value + Data("!".utf8))

            var raw = ValueViewerState(bytes: value, mode: .raw)
            XCTAssertEqual(raw.edit(String(raw.text.dropLast()) + #"\x00""#), value + Data([0]))
            // Switching views keeps the edited bytes.
            raw.show(.text)
            XCTAssertEqual(ValueText.bytes(raw.text, escaped: raw.escaped), value + Data([0]))
        }
    }

    // MARK: - Extras

    func testRawEditThatDoesNotParseKeepsLastBytesAndBlocksSave() {
        var state = ValueViewerState(bytes: Data("ab".utf8), mode: .raw)
        XCTAssertNil(state.edit(#""abc"#))
        XCTAssertEqual(state.bytes, Data("ab".utf8))
        XCTAssertEqual(state.saveBlock, "The closing quote is missing.")
        XCTAssertEqual(state.edit(#""abc""#), Data("abc".utf8))
        XCTAssertNil(state.saveBlock)
        XCTAssertNil(state.edit("x"))
        state.show(.hex)
        XCTAssertNil(state.saveBlock)
        XCTAssertEqual(state.bytes, Data("abc".utf8))
        XCTAssertNil(state.edit("ignored"))
    }

    func testJSONStrictness() {
        for valid in [#"{"a":[true,false,null,-0,0.5,1E+2,"é\n"]}"#, "[]", " {} ", #""x""#, "-1.0e-3"] {
            XCTAssertNil(ValueJSON.validate(Data(valid.utf8)), valid)
        }
        for invalid in ["", "01", "1.", "+1", "[1,]", "{'a':1}", "[\"a\u{1}\"]", #"["\x"]"#, #"["\u12"]"#, "tru", "NaN", "[1]]"] {
            XCTAssertNotNil(ValueJSON.validate(Data(invalid.utf8)), invalid)
        }
        XCTAssertNotNil(ValueJSON.validate(Data([0x5B, 0x22, 0xFF, 0x22, 0x5D])))
        // Deep nesting is an error, not a crash.
        let deep = String(repeating: "[", count: ValueJSON.maxDepth + 1) + String(repeating: "]", count: ValueJSON.maxDepth + 1)
        XCTAssertEqual(ValueJSON.validate(Data(deep.utf8))?.message, "Nesting is deeper than 512 levels.")
        let fine = String(repeating: "[", count: ValueJSON.maxDepth) + String(repeating: "]", count: ValueJSON.maxDepth)
        XCTAssertNil(ValueJSON.validate(Data(fine.utf8)))
    }

    func testViewerMemoryPerKeyPattern() {
        let colon = NamespaceSeparator.default
        XCTAssertEqual(ValueViewerMemory.pattern(of: Data("user:42".utf8), separator: colon), Data("user:*".utf8))
        XCTAssertEqual(ValueViewerMemory.pattern(of: Data("a:b:c".utf8), separator: colon), Data("a:b:*".utf8))
        XCTAssertEqual(ValueViewerMemory.pattern(of: Data("plain".utf8), separator: colon), Data("plain".utf8))
        let doubleColon = NamespaceSeparator(Data("::".utf8))!
        XCTAssertEqual(ValueViewerMemory.pattern(of: Data("a::b::c".utf8), separator: doubleColon), Data("a::b::*".utf8))

        var memory = ValueViewerMemory()
        let pattern = ValueViewerMemory.pattern(of: Data("user:1".utf8), separator: colon)
        XCTAssertNil(memory.mode(for: pattern))
        memory.remember(.hex, for: pattern)
        XCTAssertEqual(memory.mode(for: ValueViewerMemory.pattern(of: Data("user:2".utf8), separator: colon)), .hex)
        XCTAssertNil(memory.mode(for: Data("order:*".utf8)))
        for index in 0..<ValueViewerMemory.capacity { memory.remember(.raw, for: Data("p\(index)".utf8)) }
        XCTAssertNil(memory.mode(for: pattern), "the cap drops old choices instead of growing")
    }
}

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

    /// FR-SF05: a pattern that matches every non-empty key is FLUSHDB, whatever its spelling: the job refuses it and a
    /// confirmation for it covers no delete.
    func testPatternsMatchingEveryKeyAreRefused() {
        for pattern in ["*", "**", "?*", "*?", "*?*", "**?**", "[^]*", "*[^"] {
            let bytes = Data(pattern.utf8)
            XCTAssertTrue(GlobPattern.matchesEverything(bytes), pattern)
            XCTAssertTrue(BulkDeleteJob.refusal(pattern: bytes, type: nil)?.contains("FLUSHDB") ?? false, pattern)
            let yes = CommandConfirmation(scope: .pattern(bytes), database: 0)
            let arguments = ["UNLINK", "a", "b"].map { Data($0.utf8) }
            let result = SafetyPolicy.evaluate(arguments, command: CommandCatalog.bundled.resolve(arguments), origin: .bulk, profile: writable, database: 0, confirmation: yes)
            XCTAssertEqual(result.code, "CONFIRMATION_REQUIRED", pattern)
        }
        // Each of these leaves some keys alone, so it stays a bulk delete.
        for pattern in ["?", "??*", "*??", "a*", "*a", "[^a]*", "*\\*", "[a-z]*", "", "[]*"] {
            XCTAssertFalse(GlobPattern.matchesEverything(Data(pattern.utf8)), pattern)
        }
        XCTAssertTrue(GlobPattern.matchesEverything(Data([0x2A, 0x5B, 0x00, 0x2D, 0xFF, 0x5D])), "*[\\x00-\\xff] in bytes")
    }

    /// GlobPattern follows Redis/Valkey `stringmatchlen` on its edge cases, so the bulk delete's own check agrees with
    /// what SCAN MATCH returned.
    func testGlobPatternMirrorsStringmatchlen() {
        let table: [(String, String, Bool)] = [
            // `x-]` with three bytes left is a range from `]` to `x`, and that `]` doesn't close the class.
            ("[a-]]", "]", true), ("[a-]]", "_", true), ("[a-]]", "a", true), ("[a-]]", "b", false), ("[a-]]", "a]", false), ("[a-]]", "-]", false),
            ("[a-]", "_", true), ("[a-]", "-", false), ("[a-]x", "_x", false), ("[a-]x", "`", true),
            // With fewer than three bytes left `-` is literal.
            ("[a-", "-", true), ("[a-", "a", true), ("[a-", "b", false),
            // A `]` right after `[` closes an empty class, which matches nothing.
            ("[]a]", "]", false), ("[]a]", "a", false), ("[^]", "x", true), ("[^]a", "xa", true),
            // Escapes: in a class, before `]`, and a trailing backslash is literal.
            ("[\\]]", "]", true), ("[\\-a]", "-", true), ("[a\\-z]", "b", false), ("a\\", "a\\", true), ("\\?", "?", true), ("\\?", "x", false),
            // An unterminated class runs to the end of the pattern.
            ("[abc", "b", true), ("[^", "x", true), ("[", "[", false), ("a[", "a", false),
            // Exactly `*` matches every key, the empty one too (SCAN doesn't match for it); anything longer needs a byte.
            ("*", "", true), ("**", "", false), ("*?", "", false), ("?*", "a", true), ("", "", true),
            ("*a*b*c", "aXbXc", true), ("*a*b*c", "aXbXcX", false), ("a*b", "ab", true), ("a*", "a", true)
        ]
        for (pattern, subject, expected) in table {
            XCTAssertEqual(GlobPattern.matches(Data(pattern.utf8), Data(subject.utf8)), expected, "\(pattern) ~ \(subject)")
        }
        // Range bounds are C chars: unsigned on arm64 Linux, signed on x86-64, so `[a-\x90]` matches `b` (97…144) and
        // `0` (-112…97); a key matches when either server would have matched it. ASCII-only ranges read the same.
        let mixed = Data([0x5B, 0x61, 0x2D, 0x90, 0x5D])
        for byte: UInt8 in [0x62, 0x30, 0x95] { XCTAssertTrue(GlobPattern.matches(mixed, Data([byte])), "\(byte)") }
        XCTAssertFalse(GlobPattern.matches(Data("[a-z]".utf8), Data([0xE1])))
        XCTAssertTrue(GlobPattern.matches(Data([0x5B, 0x80, 0x2D, 0xFF, 0x5D]), Data([0xC3])))
        XCTAssertFalse(GlobPattern.matches(Data([0x5B, 0x80, 0x2D, 0xFF, 0x5D]), Data([0x41])))
    }

    /// The iterative matcher agrees with a line-by-line port of `stringmatchlen_impl` (unsigned `char`, as on arm64
    /// Linux) on 20,000 short patterns and keys over the bytes that matter to it (seeded, so a failure repeats).
    func testGlobPatternAgreesWithStringmatchlenPort() {
        let alphabet = Array("ab*?[]^-\\".utf8)
        // SplitMix64 with a fixed seed.
        struct SeededGenerator: RandomNumberGenerator {
            var state: UInt64 = 0x4B45_454C
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var generator = SeededGenerator()
        for _ in 0..<20_000 {
            let pattern = (0..<Int.random(in: 0...6, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            let subject = (0..<Int.random(in: 0...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }
            var skip = false
            // SCAN skips matching for exactly `*`.
            let expected = pattern == [UInt8(ascii: "*")] || Self.stringmatchlen(pattern, 0, subject, 0, &skip, 0)
            XCTAssertEqual(GlobPattern.matches(Data(pattern), Data(subject)), expected, "\(String(decoding: pattern, as: UTF8.self)) ~ \(String(decoding: subject, as: UTF8.self))")
        }
    }

    /// `util.c` `stringmatchlen_impl` (nocase off), pointer for pointer; `at` reads the sds NUL terminator past the end.
    private static func stringmatchlen(_ p: [UInt8], _ pStart: Int, _ s: [UInt8], _ sStart: Int, _ skipLongerMatches: inout Bool, _ nesting: Int) -> Bool {
        if nesting > 1000 { return false }
        var pattern = pStart, patternLen = p.count - pStart, string = sStart, stringLen = s.count - sStart
        func at(_ i: Int) -> UInt8 { i < p.count ? p[i] : 0 }
        while patternLen > 0 && stringLen > 0 {
            switch at(pattern) {
            case UInt8(ascii: "*"):
                while patternLen > 0 && at(pattern + 1) == UInt8(ascii: "*") { pattern += 1; patternLen -= 1 }
                if patternLen == 1 { return true }
                while stringLen > 0 {
                    if stringmatchlen(p, pattern + 1, s, string, &skipLongerMatches, nesting + 1) { return true }
                    if skipLongerMatches { return false }
                    string += 1; stringLen -= 1
                }
                skipLongerMatches = true
                return false
            case UInt8(ascii: "?"):
                string += 1; stringLen -= 1
            case UInt8(ascii: "["):
                pattern += 1; patternLen -= 1
                let not = patternLen > 0 && at(pattern) == UInt8(ascii: "^")
                if not { pattern += 1; patternLen -= 1 }
                var match = false
                while true {
                    if at(pattern) == UInt8(ascii: "\\") && patternLen >= 2 {
                        pattern += 1; patternLen -= 1
                        if at(pattern) == s[string] { match = true }
                    } else if at(pattern) == UInt8(ascii: "]") {
                        break
                    } else if patternLen == 0 {
                        pattern -= 1; patternLen += 1
                        break
                    } else if patternLen >= 3 && at(pattern + 1) == UInt8(ascii: "-") {
                        var start = Int(at(pattern)), end = Int(at(pattern + 2))
                        let c = Int(s[string])
                        if start > end { swap(&start, &end) }
                        pattern += 2; patternLen -= 2
                        if c >= start && c <= end { match = true }
                    } else if at(pattern) == s[string] {
                        match = true
                    }
                    pattern += 1; patternLen -= 1
                }
                if not { match.toggle() }
                if !match { return false }
                string += 1; stringLen -= 1
            default:
                if at(pattern) == UInt8(ascii: "\\") && patternLen >= 2 { pattern += 1; patternLen -= 1 }
                if at(pattern) != s[string] { return false }
                string += 1; stringLen -= 1
            }
            pattern += 1; patternLen -= 1
            if stringLen == 0 {
                while at(pattern) == UInt8(ascii: "*") { pattern += 1; patternLen -= 1 }
                break
            }
        }
        return patternLen == 0 && stringLen == 0
    }

    /// Like Redis, more than 1,000 nested `*`s match nothing, and getting there doesn't exhaust a task's stack.
    func testGlobPatternNestingLimit() async {
        let subject = Data(String(repeating: "a", count: 1_001).utf8)
        XCTAssertTrue(GlobPattern.matches(Data(String(repeating: "*a", count: 1_000).utf8), subject))
        XCTAssertFalse(GlobPattern.matches(Data(String(repeating: "*a", count: 1_001).utf8), subject))
    }
}

import Foundation
import XCTest

/// FR-AP06, NFR-PV02: nothing that ships writes to stdout, stderr or the unified log except through `KeelLog`, which
/// keeps server text private. A grep over every compiled source, comments left out.
final class SourceScanTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let scanned = ["Sources", "ThirdParty/TrellisShared"]
    private static let forbidden: [(name: String, pattern: String)] = [
        ("print", #"(?<![\w.])(Swift\.)?(print|debugPrint|dump)\s*\("#),
        ("NSLog", #"\bNSLogv?\s*\("#),
        ("os_log", #"\bos_log\s*\("#),
        ("Logger outside KeelLog", #"\b(Logger|OSLog)\s*\("#),
        ("public log interpolation", #"privacy:\s*\.public"#),
        ("stdout or stderr", #"FileHandle\.standard(Output|Error)|\b(fputs|fprintf|puts|fwrite)\s*\(|\bSTD(OUT|ERR)_FILENO\b"#)
    ]
    /// The only places allowed to match, and why.
    private static let allowed: [String: Set<String>] = [
        // The logging wrapper itself: event, codes and counts public, server text private.
        "Sources/KeelCore/KeelLog.swift": ["Logger outside KeelLog", "public log interpolation"],
        // A launch failure (a mistyped flag, an unusable state folder) goes to stderr before any connection exists.
        "Sources/KeelApp/AppMain.swift": ["stdout or stderr"],
        // keel-askpass answers ssh on stdout; that is its protocol, not logging.
        "ThirdParty/TrellisShared/KeelAskpass/Askpass.swift": ["stdout or stderr"]
    ]

    func testNoRawPrintOfValues() throws {
        let files = Self.swiftFiles()
        XCTAssertTrue(files.contains { $0.hasSuffix("Sources/KeelCore/KeelLog.swift") }, "The scan must reach Sources")
        XCTAssertTrue(files.contains { $0.hasSuffix("KeelAskpass/Askpass.swift") }, "The scan must reach the vendored folder")
        let patterns = try Self.forbidden.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var findings: [String] = []
        for path in files {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { findings.append("\(path): unreadable"); continue }
            let relative = path.replacingOccurrences(of: Self.root.path + "/", with: "")
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = Self.strippingComment(String(line))
                let range = NSRange(code.startIndex..., in: code)
                for (name, pattern) in patterns where pattern.firstMatch(in: code, range: range) != nil && Self.allowed[relative]?.contains(name) != true {
                    findings.append("\(relative):\(number + 1): \(name)")
                }
            }
        }
        XCTAssertEqual(findings, [])
    }

    func testScanCatchesRawLogging() throws {
        let patterns = try Self.forbidden.map { try NSRegularExpression(pattern: $0.pattern) }
        func caught(_ line: String) -> Bool {
            let code = Self.strippingComment(line)
            return patterns.contains { $0.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil }
        }
        for line in [
            "print(value)", "  debugPrint(key)", "NSLog(\"%@\", key)", "os_log(\"%{public}@\", key)", "let l = Logger(subsystem: s, category: c)",
            "logger.log(\"\\(key, privacy: .public)\")", "FileHandle.standardError.write(data)", "fputs(text, stderr)",
            "Swift.print(key)", "fwrite(bytes, 1, count, stdout)", "write(STDERR_FILENO, bytes, count)"
        ] {
            XCTAssertTrue(caught(line), line)
        }
        for line in ["return .printed(lines)", "/// print(value) in a comment", "let text = \"// not a comment\" // print(x)", "blueprint(x)"] {
            XCTAssertFalse(caught(line), line)
        }
    }

    private static func swiftFiles() -> [String] {
        var files: [String] = []
        for folder in scanned {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" { files.append(file.standardizedFileURL.path) }
        }
        return files
    }

    /// The line without a trailing `//` comment; a `//` inside a string literal (a URL) is kept.
    private static func strippingComment(_ line: String) -> String {
        var inString = false, previous: Character = " ", result = ""
        for character in line {
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString && character == "/" && previous == "/" { result.removeLast(); return result }
            result.append(character); previous = character
        }
        return result
    }
}

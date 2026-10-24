import Foundation
import os

/// One part of a log message (NFR-PV02). Codes, counts and server families are Keel's own words and log publicly;
/// anything that came from a server or names a target (a host, an error reply) is `serverText`, logged
/// `privacy: .private` in debug builds and left out of release builds. Values, key names and console text are never
/// passed here at all.
public enum LogField: Sendable {
    /// A SCREAMING_SNAKE code (`READ_ONLY`, `TLS_UNTRUSTED`); anything else is replaced by `INVALID_CODE`, so a key
    /// name passed by mistake can't reach the log as a public string.
    case code(String)
    case count(StaticString, Int)
    case serverKind(ServerKind)
    case serverText(String)
}

/// Debug builds may add private server text for the developer; release builds log codes and counts only.
public enum LogBuild: Sendable {
    case debug, release

    public static var current: LogBuild {
        #if DEBUG
            return .debug
        #else
            return .release
        #endif
    }
}

/// An event and its fields, split into what may be logged publicly and what may only be logged privately.
public struct LogMessage: Sendable {
    public var event: StaticString
    public var fields: [LogField]

    public init(_ event: StaticString, _ fields: [LogField]) { self.event = event; self.fields = fields }

    /// `public` holds the event, codes, counts and server families; `private` the server text, nil in release builds
    /// or when there is none.
    public func rendered(for build: LogBuild) -> (public: String, private: String?) {
        var shown = ["\(event)"], hidden: [String] = []
        for field in fields {
            switch field {
            case .code(let code): shown.append("code=\(Self.safeCode(code))")
            case .count(let name, let count): shown.append("\(name)=\(count)")
            case .serverKind(let kind): shown.append("server=\(kind.rawValue)")
            case .serverText(let text): if build == .debug { hidden.append(text) }
            }
        }
        return (shown.joined(separator: " "), hidden.isEmpty ? nil : hidden.joined(separator: " "))
    }

    /// The codes of `fields` as they are logged (diagnostics keep them).
    public var codes: [String] { fields.compactMap { if case .code(let code) = $0 { return Self.safeCode(code) } else { return nil } } }

    /// `code` when it is SCREAMING_SNAKE of at most 64 characters, else `INVALID_CODE`.
    public static func safeCode(_ code: String) -> String {
        // ASCII bytes, not `Character` classes: `isUppercase` would let `É` and other non-ASCII letters through.
        let upper = UInt8(ascii: "A")...UInt8(ascii: "Z"), digit = UInt8(ascii: "0")...UInt8(ascii: "9"), bytes = code.utf8
        guard (1...64).contains(bytes.count), let first = bytes.first, upper.contains(first) else { return "INVALID_CODE" }
        return bytes.allSatisfy { upper.contains($0) || digit.contains($0) || $0 == UInt8(ascii: "_") } ? code : "INVALID_CODE"
    }
}

/// The only way Keel writes to the unified log (NFR-PV02, FR-AP06); `SourceScanTests` keeps `print`, `NSLog`,
/// `os_log` and `Logger` out of every other file. Errors also go to `DiagnosticsRecorder` for Export Diagnostics.
public struct KeelLog: Sendable {
    public enum Category: String, Sendable { case connection, data, jobs, app }

    /// Receives each rendered message; tests replace it to see exactly what would be logged.
    public typealias Sink = @Sendable (_ level: OSLogType, _ public: String, _ private: String?) -> Void

    private let sink: Sink
    private let build: LogBuild
    private let recorder: DiagnosticsRecorder

    public init(_ category: Category, build: LogBuild = .current, recorder: DiagnosticsRecorder = .shared, sink: Sink? = nil) {
        self.build = build; self.recorder = recorder
        self.sink = sink ?? Self.unifiedLog(Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bearstouch.keel", category: category.rawValue))
    }

    public func log(_ level: OSLogType = .default, _ event: StaticString, _ fields: LogField...) { emit(level, LogMessage(event, fields)) }

    /// An `.error` event; its codes become the diagnostics' recent error codes.
    public func error(_ event: StaticString, _ fields: LogField...) { emit(.error, LogMessage(event, fields)) }

    private func emit(_ level: OSLogType, _ message: LogMessage) {
        let (shown, hidden) = message.rendered(for: build)
        sink(level, shown, hidden)
        if level == .error || level == .fault { for code in message.codes { recorder.recordError(code) } }
    }

    /// The one place a privacy level is chosen: the event, codes and counts are public, server text private.
    private static func unifiedLog(_ logger: Logger) -> Sink {
        { level, shown, hidden in
            if let hidden { logger.log(level: level, "\(shown, privacy: .public) \(hidden, privacy: .private)") } else { logger.log(level: level, "\(shown, privacy: .public)") }
        }
    }
}

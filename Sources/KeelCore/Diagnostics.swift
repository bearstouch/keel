import Foundation
import os

/// What this run has seen, for Export Diagnostics (FR-AP10): error codes and the server families connected to. In memory
/// only (NFR-PV03), bounded, and holding only Keel's own codes and `ServerKind`s, never a host, key or reply.
public final class DiagnosticsRecorder: Sendable {
    public static let shared = DiagnosticsRecorder()
    /// The most recent error codes kept; older ones are dropped.
    public static let errorLimit = 50

    private struct State {
        var errors: [DiagnosticsReport.RecentError] = []
        var servers: [ServerKind: Int] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// Keeps `code` if it is SCREAMING_SNAKE (`LogMessage.safeCode`); anything else is kept as `INVALID_CODE`.
    public func recordError(_ code: String) {
        let entry = DiagnosticsReport.RecentError(code: LogMessage.safeCode(code), at: now())
        state.withLock { state in
            state.errors.append(entry)
            if state.errors.count > Self.errorLimit { state.errors.removeFirst(state.errors.count - Self.errorLimit) }
        }
    }

    /// A session connected to a server of this family.
    public func recordConnection(_ kind: ServerKind) { state.withLock { $0.servers[kind, default: 0] += 1 } }

    /// Recent errors, newest first, and connections per server family.
    public var snapshot: (errors: [DiagnosticsReport.RecentError], servers: [ServerKind: Int]) {
        state.withLock { (Array($0.errors.reversed()), $0.servers) }
    }
}

/// The Help → Export Diagnostics file (FR-AP10, AC2): versions, counts, server types and error codes. Every field is
/// typed so nothing else fits: a count of profiles, never their hosts or names; `ServerKind`s, never addresses;
/// SCREAMING_SNAKE codes, never messages or server text.
public struct DiagnosticsReport: Sendable, Equatable, Codable {
    public struct RecentError: Sendable, Equatable, Codable {
        public var code: String
        public var at: Date

        public init(code: String, at: Date) { self.code = code; self.at = at }
    }

    public var appVersion: String
    public var macOSVersion: String
    public var architecture: String
    public var profileCount: Int
    /// Connections this run per server family (`redis`, `valkey`, `dragonfly`, `unrecognized`).
    public var serverTypes: [String: Int]
    /// Newest first, at most `DiagnosticsRecorder.errorLimit`.
    public var recentErrors: [RecentError]
    public var generatedAt: Date

    public init(
        appVersion: String, macOSVersion: OperatingSystemVersion, architecture: String, profileCount: Int, servers: [ServerKind: Int], recentErrors: [RecentError], generatedAt: Date
    ) {
        self.appVersion = appVersion; self.architecture = architecture; self.profileCount = profileCount; self.recentErrors = recentErrors; self.generatedAt = generatedAt
        self.macOSVersion = "\(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)"
        self.serverTypes = Dictionary(uniqueKeysWithValues: servers.map { ($0.key.rawValue, $0.value) })
    }

    /// This Mac and this run, with `profileCount` from the profile store.
    public static func current(profileCount: Int, recorder: DiagnosticsRecorder = .shared, now: Date = Date()) -> DiagnosticsReport {
        let seen = recorder.snapshot
        return DiagnosticsReport(
            appVersion: AppVersion.current, macOSVersion: ProcessInfo.processInfo.operatingSystemVersion, architecture: architecture, profileCount: profileCount,
            servers: seen.servers, recentErrors: seen.errors, generatedAt: now)
    }

    public static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    /// Pretty-printed JSON with sorted keys and ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static let fileName = "Keel Diagnostics.json"
}

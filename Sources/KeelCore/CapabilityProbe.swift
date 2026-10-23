import Foundation
import KeelRESP

/// Features that vary within the supported range and are probed, never assumed from the version (FR-CN12, INT-02).
public enum ServerCapability: String, Sendable, CaseIterable, Codable {
    case memoryUsage, objectEncoding, commandDocs, zrangeByScore, xrangeExclusive, pexpireTime, evalReadOnly

    /// The command (or form) a missing capability names in "unavailable" text.
    public var commandName: String {
        switch self {
        case .memoryUsage: return "MEMORY USAGE"
        case .objectEncoding: return "OBJECT ENCODING"
        case .commandDocs: return "COMMAND DOCS"
        case .zrangeByScore: return "ZRANGE … BYSCORE"
        case .xrangeExclusive: return "XRANGE exclusive ranges"
        case .pexpireTime: return "PEXPIRETIME"
        case .evalReadOnly: return "EVAL_RO"
        }
    }

    /// A read-only probe whose only side effect is the reply. Keyed probes use `key`, a name Keel picks so it almost
    /// surely doesn't exist: a missing key gives null / empty / -2 where the feature exists and an error where it doesn't.
    /// The feature is the command itself (not an argument form), so a reply that passed the command checks proves it.
    var isCommandLevel: Bool { [.memoryUsage, .objectEncoding, .pexpireTime].contains(self) }

    func probe(key: Data) -> [Data] {
        switch self {
        case .memoryUsage: return [d("MEMORY"), d("USAGE"), key]
        case .objectEncoding: return [d("OBJECT"), d("ENCODING"), key]
        case .commandDocs: return [d("COMMAND"), d("DOCS"), d("GET")]
        case .zrangeByScore: return [d("ZRANGE"), key, d("0"), d("0"), d("BYSCORE")]
        case .xrangeExclusive: return [d("XRANGE"), key, d("(0-0"), d("+"), d("COUNT"), d("1")]
        case .pexpireTime: return [d("PEXPIRETIME"), key]
        case .evalReadOnly: return [d("EVAL_RO"), d("return 0"), d("0")]
        }
    }
}

private func d(_ text: String) -> Data { Data(text.utf8) }

/// A probe's answer. `unavailable` keeps the server's error reply (it names only Keel's probe key, never user data).
public enum CapabilityStatus: Sendable, Equatable {
    case available
    case unavailable(serverError: String?)

    public var isAvailable: Bool { self == .available }
    /// The shared error code for a feature the server lacks (`specs/02-architecture.md#errors`).
    public static let unavailableCode = "UNSUPPORTED"
}

/// Probe results for one session. A capability not probed (yet) counts as unavailable, so callers take the fallback
/// that works on every supported server.
public struct CapabilitySet: Sendable, Equatable {
    public var statuses: [ServerCapability: CapabilityStatus]

    public init(_ statuses: [ServerCapability: CapabilityStatus] = [:]) { self.statuses = statuses }

    public func supports(_ capability: ServerCapability) -> Bool { statuses[capability]?.isAvailable ?? false }

    // MARK: - Editor fallbacks (FR-CN12)

    /// One page of a sorted set by score: `ZRANGE … BYSCORE LIMIT` (6.2+), else `ZRANGEBYSCORE … LIMIT` (6.0).
    /// `min` / `max` are score bounds as Redis spells them (`-inf`, `(1.5`, `+inf`); `reverse` pages from `max` down.
    public func zrangeByScore(key: Data, min: Data, max: Data, offset: Int, count: Int, withScores: Bool = true, reverse: Bool = false) -> [Data] {
        Self.zrangeByScore(byScore: supports(.zrangeByScore), key: key, min: min, max: max, offset: offset, count: count, withScores: withScores, reverse: reverse)
    }

    static func zrangeByScore(byScore: Bool, key: Data, min: Data, max: Data, offset: Int, count: Int, withScores: Bool = true, reverse: Bool = false) -> [Data] {
        // Descending ranges name the upper bound first in every form.
        let bounds = reverse ? [max, min] : [min, max]
        var args: [Data]
        if byScore {
            args = [d("ZRANGE"), key] + bounds + [d("BYSCORE")] + (reverse ? [d("REV")] : [])
        } else {
            args = [d(reverse ? "ZREVRANGEBYSCORE" : "ZRANGEBYSCORE"), key] + bounds
        }
        if withScores { args.append(d("WITHSCORES")) }
        return args + [d("LIMIT"), d(String(offset)), d(String(count))]
    }

    /// The next stream page after `lastID` (`ms-seq`): `XRANGE key (lastID + COUNT n` (6.2+), else the next possible
    /// ID as an inclusive start, so 6.0 pages without repeating the last entry. Nil when `lastID` isn't an entry ID
    /// or is the largest possible one (nothing can follow it).
    public func xrangeAfter(key: Data, lastID: Data, count: Int) -> [Data]? {
        guard StreamEditor.parseID(lastID) != nil else { return nil }
        // The exclusive form is sent for any ID; the inclusive one shares the viewer's next-ID arithmetic.
        let start = supports(.xrangeExclusive) ? d("(") + lastID : StreamEditor.bound(after: lastID, descending: false, exclusive: false)
        return start.map { [d("XRANGE"), key, $0, d("+"), d("COUNT"), d(String(count))] }
    }

    /// How to read a key's expiry: `PEXPIRETIME` (7.0+, absolute) or `PTTL` (relative, turned into a time with `now`).
    public func expiryQuery(key: Data) -> ExpiryQuery {
        supports(.pexpireTime) ? ExpiryQuery(arguments: [d("PEXPIRETIME"), key], isAbsolute: true) : ExpiryQuery(arguments: [d("PTTL"), key], isAbsolute: false)
    }
}

/// A key's expiry command and how to read its integer reply.
public struct ExpiryQuery: Sendable, Equatable {
    public var arguments: [Data]
    /// True for `PEXPIRETIME` (Unix ms), false for `PTTL` (ms from now).
    public var isAbsolute: Bool

    /// Both commands reply -2 for a missing key and -1 for a key without expiry.
    public func expiry(reply: Int64, now: Date) -> KeyExpiry {
        switch reply {
        case -1: return .persistent
        // -2, and any other negative reply a server might send, reads as a missing key.
        case ..<0: return .missing
        default:
            let milliseconds = Double(reply)
            return .at(isAbsolute ? Date(timeIntervalSince1970: milliseconds / 1_000) : now.addingTimeInterval(milliseconds / 1_000))
        }
    }
}

public enum KeyExpiry: Sendable, Equatable {
    case missing, persistent
    case at(Date)
}

/// Runs and caches the FR-CN12 probes for one server session. Each capability is probed at most once per session,
/// concurrent askers share the one probe in flight, and a connection failure caches nothing so the next ask retries.
public actor CapabilityProbe {
    /// Sends one read-only command on the session's connection and returns its reply (server errors as values).
    public typealias Send = @Sendable ([Data]) async throws(RedisError) -> RESPValue

    private let send: Send
    private let probeKey: Data
    private var results: [ServerCapability: CapabilityStatus] = [:]
    private var inFlight: [ServerCapability: Task<Result<CapabilityStatus, RedisError>, Never>] = [:]

    /// `probeKey` defaults to a random `keel:probe:<uuid>` name, so a probe never touches a real key.
    public init(probeKey: Data = Data("keel:probe:\(UUID().uuidString)".utf8), send: @escaping Send) {
        self.probeKey = probeKey; self.send = send
    }

    /// Probes on `connection`, marking every probe a read so an interrupted one reports `CONNECTION_FAILED`.
    public init(connection: RedisConnection) {
        self.init { (arguments: [Data]) async throws(RedisError) -> RESPValue in try await connection.send(arguments, mayWrite: false) }
    }

    /// Everything probed so far.
    public var cached: CapabilitySet { CapabilitySet(results) }

    public func status(_ capability: ServerCapability) async throws(RedisError) -> CapabilityStatus {
        if let known = results[capability] { return known }
        let task: Task<Result<CapabilityStatus, RedisError>, Never>
        if let running = inFlight[capability] {
            task = running
        } else {
            let arguments = capability.probe(key: probeKey)
            let send = send
            task = Task { () async -> Result<CapabilityStatus, RedisError> in
                do throws(RedisError) { return .success(Self.classify(try await send(arguments), for: capability)) } catch { return .failure(error) }
            }
            inFlight[capability] = task
        }
        let result = await task.value
        // Clear the slot only while it still holds this probe: after a failure or transient refusal a later ask may
        // already have started a new one, which a late waiter must not drop.
        if inFlight[capability] == task { inFlight[capability] = nil }
        switch result {
        case .success(let status):
            // A transient refusal (loading, busy script) says nothing about the feature: answer with the fallback now
            // and probe again next time.
            if case .unavailable(let error?) = status, Self.isTransient(error) { return status }
            results[capability] = status
            return status
        case .failure(let error):
            throw error
        }
    }

    /// Probes every capability not yet known, one after another on the session's connection.
    public func probeAll() async throws(RedisError) -> CapabilitySet {
        for capability in ServerCapability.allCases { _ = try await status(capability) }
        return cached
    }

    /// Any non-error reply means the server understood the probe. "No such key" (older `OBJECT ENCODING`) also means
    /// the command exists. A cluster redirect (`MOVED` / `ASK`, the random probe key hashes to another node) or a
    /// key-pattern ACL denial comes after the server has accepted the command name, arity and command ACL, so it proves
    /// a command-level capability; for a syntax capability (`BYSCORE`, exclusive `XRANGE`) it proves nothing and the
    /// fallback, which works everywhere, is used. Every other error (unknown command or subcommand, syntax, a command
    /// `NOPERM`, a disabled command) leaves the feature unavailable, and the caller takes the fallback.
    static func classify(_ reply: RESPValue, for capability: ServerCapability? = nil) -> CapabilityStatus {
        switch reply {
        case .error(let bytes), .blobError(let bytes):
            let text = String(decoding: bytes.prefix(512), as: UTF8.self)
            if text.localizedCaseInsensitiveContains("no such key") { return .available }
            if capability?.isCommandLevel == true, isPastCommandChecks(text) { return .available }
            return .unavailable(serverError: text)
        case .attribute(_, let inner): return classify(inner, for: capability)
        default: return .available
        }
    }

    /// A refusal for the key alone: a cluster redirect, or an ACL that allows the command but not Keel's probe key.
    private static func isPastCommandChecks(_ serverError: String) -> Bool {
        let code = serverError.prefix(while: { !$0.isWhitespace }).uppercased()
        if code == "MOVED" || code == "ASK" { return true }
        return code == "NOPERM" && (serverError.localizedCaseInsensitiveContains("access a key") || serverError.localizedCaseInsensitiveContains("access one of the keys"))
    }

    private static func isTransient(_ serverError: String) -> Bool {
        let code = serverError.prefix(while: { !$0.isWhitespace }).uppercased()
        return ["LOADING", "BUSY", "TRYAGAIN", "MASTERDOWN", "CLUSTERDOWN"].contains(code)
    }
}

import Foundation

/// Who is asking (02 Architecture → One data path). Origin never relaxes a rule; it selects what may run at all
/// (only the console runs scripts, admin and streaming commands) and which connection role carries the command.
public enum CommandOrigin: Sendable, Hashable {
    case editor, browser, console, bulk
}

/// What a command does, as far as the policy cares (02 Architecture → Safety policy).
public enum SafetyClass: String, Sendable, Equatable {
    /// `readonly` and not `write` (`GET`, `SCAN`, `EVAL_RO`, `SORT_RO`).
    case read
    /// `write`, or `may_replicate` without `readonly` (`PUBLISH`).
    case write
    /// Multi-key `DEL` / `UNLINK`, `FLUSHDB`, `FLUSHALL`: typed confirmation.
    case destructive
    /// A script or function command that may write (`EVAL`, `EVALSHA`, `FCALL`, `SCRIPT …`, `FUNCTION …`).
    case script
    /// `admin`, or `dangerous` and `write` (`SHUTDOWN`, `CONFIG SET`, `MIGRATE`, `SWAPDB`, `RESTORE`, `SORT`).
    case admin
    /// `KEYS`: console only, after a confirmation that warns with DBSIZE.
    case keys
    /// `MONITOR`, `SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE`: console only, on a dedicated `stream` connection.
    case streaming
    /// Connection state the console keeps for itself (`SELECT`, `MULTI`/`EXEC`, `WATCH`, `HELLO`, `AUTH`, `RESET`).
    /// Other origins share connections the service owns, so they never send these.
    case session
    /// Known, with no data effect (`PING`, `INFO`, `COMMAND`; `CLIENT LIST` is admin).
    case neutral
    /// Never sent: `CLIENT REPLY` would leave Keel's reply queue waiting for replies that never come.
    case forbidden
    /// Not in the server's or the bundled catalog, an unknown subcommand, or a module command with no flags.
    case unknown

    /// Whether an interrupted command reports `OUTCOME_UNKNOWN`: only commands that can't change data are reads.
    public var mayWrite: Bool {
        switch self {
        case .read, .keys, .neutral: return false
        default: return true
        }
    }
}

/// The user's yes to one destructive or console-confirmed command (FR-SF03), created by the UI after its sheet
/// (typed when the request had `typedText`). Core checks that it covers the exact command and database.
public struct CommandConfirmation: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        /// Exactly these arguments, byte for byte.
        case command([Data])
        /// `DEL` / `UNLINK` batches whose keys are all in the confirmed selection (FR-SF04).
        case keys(Set<Data>)
        /// `DEL` / `UNLINK` batches whose keys all match the confirmed pattern (FR-SF05); `*` never qualifies.
        case pattern(Data)
    }

    public var scope: Scope
    public var database: Int

    public init(scope: Scope, database: Int) { self.scope = scope; self.database = database }
}

/// What the UI must ask before the command can run.
public struct ConfirmationRequest: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case deleteKeys(count: Int)
        case flushDatabase(Int)
        case flushAll
        /// The command as typed in the console's confirmation sheet ("CONFIG SET").
        case admin(command: String)
        /// `KEYS`: the console warns with DBSIZE before asking.
        case keys
    }

    public var operation: Operation
    /// FR-SF03: the text the user must type (key count, `db3`, the profile name); nil for a plain confirmation.
    public var typedText: String?
    /// Names the command, profile and database; never a key name or value.
    public var message: String
}

/// The policy's answer. Anything but `allow` sends nothing.
public enum SafetyVerdict: Sendable, Equatable {
    case allow(SafetyClass)
    case readOnly(message: String)
    case blocked(message: String)
    case confirmationRequired(ConfirmationRequest)

    public var isAllowed: Bool { if case .allow = self { return true } else { return false } }

    /// The shared error code (`docs/architecture.md#errors`); nil when allowed.
    public var code: String? {
        switch self {
        case .allow: return nil
        case .readOnly: return "READ_ONLY"
        case .blocked: return "BLOCKED_COMMAND"
        case .confirmationRequired: return "CONFIRMATION_REQUIRED"
        }
    }
}

/// The profile facts the policy needs.
public struct SafetyProfile: Sendable, Equatable {
    public var name: String
    public var readOnly: Bool
    /// The profile's label is treated as production (FR-SF02): some actions that are plain elsewhere ask first (a list pop).
    public var production: Bool
    /// Where the profile connects (`cache.internal:6379`); typed confirmations on production name it (FR-SF03).
    public var server: String?

    public init(name: String, readOnly: Bool, production: Bool = false, server: String? = nil) {
        self.name = name; self.readOnly = readOnly; self.production = production; self.server = server
    }
}

/// Classifies every command before it is sent and decides whether it may go (02 Architecture → Safety policy,
/// FR-SF01). Pure: the same arguments, catalog entry, origin and context always give the same verdict.
public enum SafetyPolicy {
    /// The unsubscribe commands too: one call answers once per channel (pushes on RESP3), which would desynchronise a
    /// shared connection's reply queue, so they belong with SUBSCRIBE on the console's stream connection.
    static let streamingNames: Set<String> = ["monitor", "subscribe", "psubscribe", "ssubscribe", "unsubscribe", "punsubscribe", "sunsubscribe"]
    static let sessionNames: Set<String> = [
        "select", "hello", "auth", "reset", "quit", "multi", "exec", "discard", "watch", "unwatch", "readonly", "readwrite", "asking", "client|tracking",
        "client|caching"
    ]
    static let forbiddenNames: Set<String> = ["client|reply"]
    /// What read-only refuses, whoever asks (unknown fails closed).
    public static let readOnlyRefused: Set<SafetyClass> = [.write, .destructive, .script, .admin, .unknown]

    /// `command` is the catalog's resolution of `arguments` (nil when unknown).
    public static func classify(_ arguments: [Data], command: CommandInfo?) -> SafetyClass {
        guard !arguments.isEmpty else { return .forbidden }
        guard let command else { return .unknown }
        let name = command.name, flags = command.flags
        if forbiddenNames.contains(name) { return .forbidden }
        // Fixed rules first: MONITOR is also `admin`, KEYS also `readonly`, FLUSHALL also `write`.
        if streamingNames.contains(name) { return .streaming }
        if name == "keys" { return .keys }
        if name == "flushdb" || name == "flushall" { return .destructive }
        if name == "del" || name == "unlink" { return arguments.count > 2 ? .destructive : .write }
        if sessionNames.contains(name) { return .session }
        // `dangerous` alone also marks reads (INFO, ROLE, LASTSAVE, SORT_RO); with `write` it is admin-grade. Before
        // scripts, so a scripting command a server flags admin stays admin.
        if flags.contains(.admin) || flags.isSuperset(of: [.dangerous, .write]) { return .admin }
        if command.docs?.group == "scripting", !flags.contains(.readonly) { return .script }
        if flags.contains(.write) || (flags.contains(.mayReplicate) && !flags.contains(.readonly)) { return .write }
        if flags.contains(.readonly) { return .read }
        // Neither flag: only a core command (it has a group) is harmless. A module or live-only command that declares
        // nothing may still write, so it fails closed like an unknown one.
        guard let group = command.docs?.group, group != "module" else { return .unknown }
        return .neutral
    }

    public static func evaluate(_ arguments: [Data], command: CommandInfo?, origin: CommandOrigin, profile: SafetyProfile, database: Int, confirmation: CommandConfirmation?)
        -> SafetyVerdict
    {
        let safetyClass = classify(arguments, command: command)
        let display = command?.displayName ?? "This command"
        // 1. Read-only blocks every possible write, whoever asks (unknown fails closed).
        if profile.readOnly, readOnlyRefused.contains(safetyClass) {
            return .readOnly(message: "Write commands are blocked on this connection (\(profile.name) is read-only).")
        }
        // 2. What each origin may run.
        switch safetyClass {
        case .read, .write, .neutral:
            return .allow(safetyClass)
        case .destructive:
            let request = destructiveRequest(arguments, command: command, profile: profile, database: database)
            return confirmed(arguments, safetyClass, request, database: database, confirmation: confirmation)
        case .script:
            // Editors, the browser and bulk jobs never run scripts.
            return origin == .console ? .allow(.script) : consoleOnly(display)
        case .admin, .keys:
            guard origin == .console else { return consoleOnly(display) }
            let request =
                safetyClass == .keys
                ? ConfirmationRequest(operation: .keys, typedText: nil, message: "KEYS blocks the server while it walks every key in db\(database).")
                : ConfirmationRequest(operation: .admin(command: display), typedText: nil, message: "\(display) changes the server \(profile.name).")
            return confirmed(arguments, safetyClass, request, database: database, confirmation: confirmation)
        case .streaming, .session, .unknown:
            // The console runs these on its own (or a dedicated stream) connection; unknown ones with a notice.
            return origin == .console ? .allow(safetyClass) : consoleOnly(display)
        case .forbidden:
            // Not in either deny list above, so it lands here for every origin and profile.
            return .blocked(message: "\(display) can't be sent from Keel.")
        }
    }

    private static func consoleOnly(_ display: String) -> SafetyVerdict { .blocked(message: "\(display) runs only in the console.") }

    private static func destructiveRequest(_ arguments: [Data], command: CommandInfo?, profile: SafetyProfile, database: Int)
        -> ConfirmationRequest
    {
        let display = command?.displayName ?? ""
        let asking = "needs a typed confirmation"
        switch command?.name {
        case "flushall":
            return ConfirmationRequest(operation: .flushAll, typedText: profile.name, message: "FLUSHALL on \(profile.name) \(asking).")
        case "flushdb":
            return ConfirmationRequest(operation: .flushDatabase(database), typedText: "db\(database)", message: "FLUSHDB on \(profile.name) db\(database) \(asking).")
        default:
            let count = arguments.count - 1
            return ConfirmationRequest(
                operation: .deleteKeys(count: count), typedText: String(count), message: "\(display) of \(count) keys on \(profile.name) db\(database) \(asking).")
        }
    }

    /// Allows when `confirmation` covers this command and database; otherwise asks for one.
    private static func confirmed(_ arguments: [Data], _ safetyClass: SafetyClass, _ request: ConfirmationRequest, database: Int, confirmation: CommandConfirmation?)
        -> SafetyVerdict
    {
        if let confirmation, confirmation.database == database, covers(confirmation.scope, arguments, safetyClass) { return .allow(safetyClass) }
        return .confirmationRequired(request)
    }

    private static func covers(_ scope: CommandConfirmation.Scope, _ arguments: [Data], _ safetyClass: SafetyClass) -> Bool {
        switch scope {
        case .command(let confirmed):
            return confirmed == arguments
        case .keys(let selection):
            return isKeyDeletion(arguments, safetyClass) && arguments.dropFirst().allSatisfy(selection.contains)
        case .pattern(let pattern):
            // A pattern every key matches (`*`, `?*`, …) deletes everything: that is FLUSHDB, with its own confirmation (FR-SF05).
            guard !GlobPattern.matchesEverything(pattern), isKeyDeletion(arguments, safetyClass) else { return false }
            return arguments.dropFirst().allSatisfy { GlobPattern.matches(pattern, $0) }
        }
    }

    /// A multi-key `DEL` / `UNLINK`: the only commands a key-set or pattern confirmation can cover.
    private static func isKeyDeletion(_ arguments: [Data], _ safetyClass: SafetyClass) -> Bool {
        guard safetyClass == .destructive, let name = arguments.first.map({ String(decoding: $0, as: UTF8.self).lowercased() }) else { return false }
        return name == "del" || name == "unlink"
    }
}

/// Redis glob matching (`stringmatchlen`, case-sensitive) on bytes: `*`, `?`, `[abc]`, `[^a-z]`, `\x`.
public enum GlobPattern {
    public static func matches(_ pattern: Data, _ subject: Data) -> Bool {
        let p = [UInt8](pattern), s = [UInt8](subject)
        var pi = 0, si = 0
        // Every token but `*` consumes exactly one byte, so backtracking to the last `*` is enough (no recursion).
        var starPattern: Int?, starSubject = 0
        while si < s.count {
            if pi < p.count, p[pi] == UInt8(ascii: "*") {
                while pi < p.count, p[pi] == UInt8(ascii: "*") { pi += 1 }
                starPattern = pi; starSubject = si
                continue
            }
            if pi < p.count, let next = matchOne(p, pi, s[si]) {
                pi = next; si += 1
                continue
            }
            guard let star = starPattern else { return false }
            starSubject += 1; si = starSubject; pi = star
        }
        while pi < p.count, p[pi] == UInt8(ascii: "*") { pi += 1 }
        return pi == p.count
    }

    /// A pattern that matches every non-empty key (FR-SF05 refuses it; that is FLUSHDB): at least one `*` and at most
    /// one other token, which matches every byte (`?`, `[^]`, `[\x00-\xff]`, …). `*`, `?*`, `*?*`, `[^]*` are such
    /// patterns; `??*` (not 1-byte keys) and `?` (only 1-byte keys) are not.
    public static func matchesEverything(_ pattern: Data) -> Bool {
        let p = [UInt8](pattern)
        var pi = 0, stars = 0, others = 0
        while pi < p.count {
            if p[pi] == UInt8(ascii: "*") { stars += 1; pi += 1; continue }
            // Every byte must match the token; the index after it doesn't depend on which one did.
            let nexts = (0...UInt8.max).map { matchOne(p, pi, $0) }
            guard let next = nexts[0], nexts.allSatisfy({ $0 == next }) else { return false }
            others += 1; pi = next
            if others > 1 { return false }
        }
        return stars > 0
    }

    /// The pattern index after the token at `pi` when it matches `byte`; nil when it doesn't.
    private static func matchOne(_ p: [UInt8], _ pi: Int, _ byte: UInt8) -> Int? {
        switch p[pi] {
        case UInt8(ascii: "?"):
            return pi + 1
        case UInt8(ascii: "\\") where pi + 1 < p.count:
            return p[pi + 1] == byte ? pi + 2 : nil
        case UInt8(ascii: "["):
            var i = pi + 1
            let negate = i < p.count && p[i] == UInt8(ascii: "^")
            if negate { i += 1 }
            var matched = false
            // Like Redis, an unterminated class runs to the end of the pattern.
            while i < p.count, p[i] != UInt8(ascii: "]") {
                if p[i] == UInt8(ascii: "\\"), i + 1 < p.count {
                    if p[i + 1] == byte { matched = true }
                    i += 2
                } else if i + 2 < p.count, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != UInt8(ascii: "]") {
                    let low = min(p[i], p[i + 2]), high = max(p[i], p[i + 2])
                    if (low...high).contains(byte) { matched = true }
                    i += 3
                } else {
                    if p[i] == byte { matched = true }
                    i += 1
                }
            }
            return matched != negate ? min(i + 1, p.count) : nil
        default:
            return p[pi] == byte ? pi + 1 : nil
        }
    }
}

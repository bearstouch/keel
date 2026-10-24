import Foundation
import KeelRESP

/// The ⋯ menu's actions on the open key (FR-ED10–FR-ED12): rename, TTL and delete. Each is one command through the
/// data path, so the safety policy decides first (a read-only profile sends nothing).
public enum KeyActions {
    // MARK: - Rename (FR-ED10)

    public enum RenameOutcome: Sendable, Equatable {
        case renamed
        /// `RENAMENX` found the target taken and changed nothing; the user's yes is this token, for exactly this rename.
        case targetExists(RenameOverwrite)
    }

    /// The user's yes to replacing `target` with `key`. Only a `targetExists` outcome makes one, so `RENAME` (which
    /// replaces) never runs without the question having been asked about the same two names. Its memberwise initializer
    /// is internal, so the UI can't make one.
    public struct RenameOverwrite: Sendable, Equatable {
        public let key: Data
        public let target: Data
    }

    /// `RENAMENX key newKey`, or `RENAME` with the overwrite confirmed for these names. A reply lost on the way is
    /// re-read (`TYPE` of both names), never re-sent: gone from the old name and present at the new one is a rename.
    public static func rename(_ key: Data, to newKey: Data, overwrite: RenameOverwrite? = nil, service: DataCommandService, context: DataContext)
        async throws(DataCommandError) -> RenameOutcome
    {
        guard !newKey.isEmpty else { throw .invalidRequest("A key name can't be empty.") }
        guard newKey != key else { throw .invalidRequest("The new name is the key's current name.") }
        if let overwrite, overwrite.key != key || overwrite.target != newKey { throw .invalidRequest("The overwrite was confirmed for another rename.") }
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await EditorReads.read(.rename(key: key, newKey: newKey, overwrite: overwrite != nil), service, context)
        } catch {
            guard isUnknownOutcome(error) else { throw error }
            // Anything short of a clear "moved" (either read failed, or both names exist) stays unknown.
            let (old, new) = (await exists(key, service, context), await exists(newKey, service, context))
            if old == false, new == true { return .renamed }
            throw error
        }
        switch reply {
        case .integer(1), .simpleString: return .renamed
        case .integer(0): return .targetExists(RenameOverwrite(key: key, target: newKey))
        default: throw EditorReads.unexpected(reply, type: "rename")
        }
    }

    // MARK: - TTL (FR-ED11)

    /// The Set TTL sheet's presets.
    public enum TTLPreset: String, Sendable, CaseIterable, Identifiable {
        case minute = "1 min", hour = "1 h", day = "1 day", week = "7 days"

        public var id: String { rawValue }
        public var milliseconds: Int64 {
            switch self {
            case .minute: return 60_000
            case .hour: return 3_600_000
            case .day: return 86_400_000
            case .week: return 7 * 86_400_000
            }
        }
    }

    public enum TTLChange: Sendable, Equatable {
        /// A preset or a custom duration: `PEXPIRE`.
        case after(milliseconds: Int64)
        /// An absolute date and time: `PEXPIREAT`.
        case at(Date)
        /// `PERSIST`: no expiry.
        case persist

        public static func preset(_ preset: TTLPreset) -> TTLChange { .after(milliseconds: preset.milliseconds) }
    }

    /// Applies `change` and returns the expiry the server now has. A zero, negative or past expiry is refused before
    /// anything is sent: Redis would delete the key at once, which is Delete's job (with its confirmation).
    public static func setTTL(
        _ key: Data, _ change: TTLChange, service: DataCommandService, context: DataContext, now: @Sendable () -> Date = Date.init
    ) async throws(DataCommandError) -> KeyExpiry {
        let operation: DataOperation
        switch change {
        case .after(let milliseconds):
            guard milliseconds > 0 else { throw .invalidRequest("A TTL must be longer than zero.") }
            operation = .expire(key: key, milliseconds: milliseconds)
        case .at(let date):
            guard date > now() else { throw .invalidRequest("That time has already passed.") }
            operation = .expireAt(key: key, unixMilliseconds: unixMilliseconds(date))
        case .persist:
            operation = .persist(key: key)
        }
        let reply = try await EditorReads.read(operation, service, context)
        switch reply {
        // PERSIST answers 0 for a key without an expiry too, so only the read below can say the key is gone.
        case .integer(0) where change != .persist: throw EditorReads.gone
        case .integer: break
        default: throw EditorReads.unexpected(reply, type: "TTL change")
        }
        return await expiry(of: key, service: service, context: context, now: now)
    }

    /// When the key expires: `PEXPIRETIME` where the probe finds it (7.0+), else now plus `PTTL`.
    public static func expiry(of key: Data, service: DataCommandService, context: DataContext, now: @Sendable () -> Date = Date.init) async -> KeyExpiry {
        let absolute = await service.supports(.pexpireTime, context: context)
        let operation: DataOperation = absolute ? .expireTime(key: key) : .pttl(key: key)
        // A server error (an ACL refusal) or a failed read: unknown, not "no expiry".
        guard case .integer(let reply)? = try? await EditorReads.read(operation, service, context) else { return .unavailable }
        return ExpiryQuery(arguments: operation.arguments, isAbsolute: absolute).expiry(reply: reply, now: now())
    }

    /// Rounded up, so a time a moment away never becomes one already past.
    static func unixMilliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded(.up)) }

    // MARK: - Delete (FR-ED12)

    /// `UNLINK key` after the UI's normal confirmation (one key is a plain write to the policy). A key already gone
    /// counts as deleted; a reply lost on the way is re-read with `TYPE`, never re-sent.
    public static func delete(_ key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) {
        let reply: RESPValue
        do throws(DataCommandError) {
            reply = try await EditorReads.read(.delete(keys: [key]), service, context)
        } catch {
            // Only a definite "gone" settles it; a failed re-read keeps the unknown outcome.
            guard isUnknownOutcome(error), await exists(key, service, context) == false else { throw error }
            return
        }
        guard case .integer = reply else { throw EditorReads.unexpected(reply, type: "delete") }
    }

    // MARK: - Helpers

    /// A timeout counts too: the command may have reached the server before the reply was lost.
    private static func isUnknownOutcome(_ error: DataCommandError) -> Bool {
        switch error {
        case .command(.outcomeUnknown), .command(.timeout): return true
        default: return false
        }
    }

    /// Whether `key` exists (`TYPE` isn't `none`); nil when that couldn't be read.
    private static func exists(_ key: Data, _ service: DataCommandService, _ context: DataContext) async -> Bool? {
        switch try? await EditorReads.read(.type(key: key), service, context) {
        case .simpleString(let name)?, .bulkString(let name)?: return name != Data("none".utf8)
        default: return nil
        }
    }
}

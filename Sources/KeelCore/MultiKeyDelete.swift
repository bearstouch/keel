import Foundation
import KeelRESP

/// Deleting several selected keys (FR-SF04): `UNLINK` in batches of 500 through the data path, after the typed
/// confirmation (FR-SF03). The confirmation covers exactly the selected keys, so a batch naming any other key is
/// refused by the policy before it is sent.
public enum MultiKeyDelete {
    public static let batchSize = 500

    /// Why a run stopped before its last batch. Batches already answered stay deleted.
    public enum Failure: Sendable, Equatable {
        /// The data path refused or lost a batch (`READ_ONLY`, `CONFIRMATION_REQUIRED`, `OUTCOME_UNKNOWN` …).
        case command(DataCommandError)
        /// The server answered a batch with an error (an ACL refusal); nothing in that batch was deleted.
        case server(String)
        /// The task was cancelled between batches.
        case cancelled
    }

    public struct Report: Sendable, Equatable {
        public var requested: Int
        /// The keys of every batch the server answered: none of them exists any more.
        public var removed: [Data]
        /// What the `UNLINK` replies counted: keys that still existed when their batch ran.
        public var deleted: Int
        public var failure: Failure?

        public var isComplete: Bool { failure == nil }
    }

    /// The yes the typed confirmation gives: these keys in this database, and no others.
    public static func confirmation(for keys: [Data], database: Int) -> CommandConfirmation {
        CommandConfirmation(scope: .keys(Set(keys)), database: database)
    }

    /// The typed confirmation the UI shows first: the number of distinct keys.
    public static func request(for keys: [Data], profile: SafetyProfile, database: Int) -> TypedConfirmation {
        TypedConfirmation(operation: .deleteKeys(count: unique(keys).count), profile: profile, database: database)
    }

    /// Sends one `UNLINK` per 500 keys, in order, and stops at the first batch that fails. A batch whose reply was lost
    /// is never re-sent (`OUTCOME_UNKNOWN`): its keys stay out of `removed`, and a refresh shows what is left.
    /// `context.confirmation` must be `confirmation(for:database:)` of the same keys.
    public static func run(_ keys: [Data], service: DataCommandService, context: DataContext, origin: CommandOrigin = .browser) async -> Report {
        let keys = unique(keys)
        var report = Report(requested: keys.count, removed: [], deleted: 0, failure: nil)
        for start in stride(from: 0, to: keys.count, by: batchSize) {
            if Task.isCancelled { report.failure = .cancelled; return report }
            let batch = Array(keys[start..<min(start + batchSize, keys.count)])
            let reply: RESPValue
            do throws(DataCommandError) {
                reply = try await service.execute(.operation(.delete(keys: batch)), origin: origin, context: context).reply
            } catch {
                report.failure = .command(error); return report
            }
            switch reply {
            case .integer(let count):
                report.deleted += Int(count); report.removed += batch
            case .error(let text), .blobError(let text):
                report.failure = .server(String(decoding: text.prefix(512), as: UTF8.self)); return report
            default:
                // Not an UNLINK reply: what happened to this batch is unknown, so nothing more is sent.
                report.failure = .command(.command(.outcomeUnknown)); return report
            }
        }
        return report
    }

    /// The first occurrence of each key, in order: the count the user types is the number of keys deleted.
    static func unique(_ keys: [Data]) -> [Data] {
        var seen = Set<Data>()
        return keys.filter { seen.insert($0).inserted }
    }
}

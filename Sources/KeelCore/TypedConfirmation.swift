import Foundation

/// What the shared typed-confirmation sheet asks (FR-SF03, DS-03): the destructive button stays disabled until the
/// field holds `expected` exactly — same case, no trimmed whitespace — and Return never confirms (NFR-UX03).
public struct TypedConfirmation: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        /// Several keys from the browser's selection (FR-SF04): type the number of keys.
        case deleteKeys(count: Int)
        /// Bulk delete by pattern (FR-SF05): type the pattern.
        case deletePattern(Data)
        /// FLUSHDB: type the database, `db3`.
        case flushDatabase(Int)
        /// FLUSHALL: type the profile name.
        case flushAll
    }

    public var operation: Operation
    /// "Delete 2,000 keys?"
    public var title: String
    /// One sentence naming the profile and database; never a value.
    public var message: String
    /// The bytes the field must hold. A pattern is bytes, so it is compared as bytes.
    public var expected: Data
    /// Production profiles only: the server the operation reaches ("Server: cache.internal:6379").
    public var serverLine: String?
    /// The destructive button's title.
    public var actionTitle: String

    /// The text to type, as the prompt shows it (escaped like a key name when it isn't printable).
    public var expectedText: String { KeyDisplay.name(expected) }

    /// "Type 2000 to confirm."
    public var prompt: String { "Type \(expectedText) to confirm." }

    /// Exactly the expected text: `Db3`, ` db3` or `db3 ` don't match `db3`.
    public func matches(_ typed: String) -> Bool { Data(typed.utf8) == expected }

    public init(operation: Operation, profile: SafetyProfile, database: Int) {
        self.operation = operation
        let target = "\(profile.name) db\(database)"
        switch operation {
        case .deleteKeys(let count):
            title = "Delete \(KeyIndexFooter.grouped(count)) keys?"
            message = "The selected keys are removed from \(target). This can't be undone."
            expected = Data(String(count).utf8); actionTitle = "Delete"
        case .deletePattern(let pattern):
            title = "Delete keys matching \(KeyDisplay.name(pattern))?"
            message = "Every key matching the pattern is removed from \(target). This can't be undone."
            expected = pattern; actionTitle = "Delete"
        case .flushDatabase(let index):
            title = "Flush db\(index)?"
            message = "Every key in \(profile.name) db\(index) is removed. This can't be undone."
            expected = Data("db\(index)".utf8); actionTitle = "Flush Database"
        case .flushAll:
            title = "Flush every database?"
            message = "Every key in every database of \(profile.name) is removed. This can't be undone."
            expected = Data(profile.name.utf8); actionTitle = "Flush All"
        }
        serverLine = profile.production ? "Server: \(profile.server ?? profile.name)" : nil
    }

    /// The sheet for a policy refusal that asked for typed text (the console's FLUSHDB, FLUSHALL and multi-key DEL);
    /// nil for a plain confirmation (admin, KEYS).
    public init?(_ request: ConfirmationRequest, profile: SafetyProfile, database: Int) {
        guard request.typedText != nil else { return nil }
        switch request.operation {
        case .deleteKeys(let count): self.init(operation: .deleteKeys(count: count), profile: profile, database: database)
        case .flushDatabase(let index): self.init(operation: .flushDatabase(index), profile: profile, database: database)
        case .flushAll: self.init(operation: .flushAll, profile: profile, database: database)
        case .admin, .keys: return nil
        }
    }
}

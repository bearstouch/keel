import Foundation
import KeelRESP

/// The string editor (FR-ED01): the whole value in the viewer, saved with `SET … KEEPTTL` inside the shell's
/// `WATCH` + `MULTI/EXEC`. Values up to 1 MiB load at once; larger ones show their first 1 MiB (`GETRANGE`) read-only
/// until "Load all" reads the rest, which is offered while the value fits one bounded reply (NFR-RS03).
public enum StringEditor {
    /// The largest value read whole on open, and the size of a large value's first page.
    public static let fullLoadLimit: Int64 = 1_024 * 1_024
    /// The largest value "Load all" reads: 64 MiB less room for the bulk header and CRLFs, so `GET`'s reply stays within
    /// the connection's reply bound instead of failing with `LIMIT_EXCEEDED` and resetting the connection.
    public static let loadAllLimit = Int64(RESPLimits.standard.maxReplyBytes - 32)

    public static let binding = EditorBinding(load: load, writes: writes, loadAll: loadAll)

    /// `STRLEN` first, so a large value is never read whole by accident: up to 1 MiB `GET`, else the first page.
    @Sendable public static func load(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let length = try await strlen(key, service, context)
        guard length > fullLoadLimit else { return try await whole(key, service, context) }
        let page = DataOperation.getRange(key: key, start: 0, end: Int(fullLoadLimit) - 1)
        let reply = try await read(page, service, context)
        guard case .bulkString(let bytes) = reply else { throw unexpected(reply) }
        // The guard is never used (partial loads don't save) but is what this view of the key depends on.
        let watch = WatchGuard(key: key, reads: [.length(key: key, command: .strlen), page], expected: [.integer(length), reply])
        return LoadedValue(
            rows: [EditorRow(id: Data(), value: bytes)], watch: watch,
            partial: PartialLoad(loadedBytes: Int64(bytes.count), totalBytes: length, canLoadAll: length <= loadAllLimit))
    }

    /// "Load all": the whole value, refused before reading when it outgrew the reply bound since the first page.
    @Sendable public static func loadAll(key: Data, service: DataCommandService, context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let length = try await strlen(key, service, context)
        guard length <= loadAllLimit else {
            throw .invalidRequest("The value is \(PartialLoad.binary(length)), more than Keel loads at once (64 MiB).")
        }
        return try await whole(key, service, context)
    }

    /// `SET key value KEEPTTL` when the draft differs; nothing for an unchanged value, so a no-op save sends nothing.
    @Sendable public static func writes(key: Data, loaded: [EditorRow], draft: [EditorRow]) -> [DataOperation] {
        guard let value = draft.first?.value, loaded.first?.value != value else { return [] }
        return [.stringSet(key: key, value: value, keepTTL: true)]
    }

    /// `GET`, guarded by its own reply: a save re-reads it under `WATCH`, so any change since loading is a `CONFLICT`.
    private static func whole(_ key: Data, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> LoadedValue {
        let reply = try await read(.get(key: key), service, context)
        guard case .bulkString(let bytes) = reply else { throw unexpected(reply) }
        return LoadedValue(rows: [EditorRow(id: Data(), value: bytes)], watch: WatchGuard(key: key, reads: [.get(key: key)], expected: [reply]))
    }

    private static func strlen(_ key: Data, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> Int64 {
        try await EditorReads.integer(.length(key: key, command: .strlen), service, context, type: "string")
    }

    private static func read(_ operation: DataOperation, _ service: DataCommandService, _ context: DataContext) async throws(DataCommandError) -> RESPValue {
        try await EditorReads.read(operation, service, context)
    }

    private static func unexpected(_ reply: RESPValue) -> DataCommandError { EditorReads.unexpected(reply, type: "string") }
}

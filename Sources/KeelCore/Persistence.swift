import Darwin
import Foundation

/// Keel's durable state files (02 Architecture → Persistence). Each lives directly in the state folder.
public enum PersistedFile: String, CaseIterable, Sendable {
    case connections, hosts, windows, settings, grants
    case knownCA = "known-ca"

    public var fileName: String { "\(rawValue).json" }
    /// Grants and CA fingerprints keep no backup: restoring an old copy could revive a revoked grant or a replaced CA.
    public var backupName: String? {
        switch self {
        case .connections, .hosts, .windows, .settings: return "\(rawValue).backup.json"
        case .grants, .knownCA: return nil
        }
    }
    func corruptName(_ id: UUID) -> String { "\(rawValue).corrupt.\(id.uuidString).json" }
    var temporaryPrefix: String { ".\(rawValue)." }
}

/// A document stored in one `PersistedFile`. It must encode as a JSON object: the envelope adds a top-level
/// `schemaVersion` beside the document's own keys, so `hosts.json` keeps the vendored host library's shape.
public protocol PersistedDocument: Codable, Sendable {
    static var file: PersistedFile { get }
    /// Starts at 1; bump it with every format change and keep `migrate` able to read each older version.
    static var currentVersion: Int { get }
    /// Reads a file written in an older version (`1..<currentVersion`). Migration happens in memory only;
    /// the next save publishes the current version. The default assumes the shape did not change.
    static func migrate(from version: Int, decoder: any Decoder) throws -> Self
}

extension PersistedDocument {
    public static func migrate(from version: Int, decoder: any Decoder) throws -> Self { try Self(from: decoder) }
}

public enum PersistenceError: Error, Equatable, Sendable {
    /// Unparsable, invalid, oversized (> 4 MiB) or nested deeper than 128 levels.
    case corrupt
    /// Written by a newer Keel; the file opens read-only and is never overwritten this session.
    case newerVersion(Int)
    /// Saving is off: not loaded yet, awaiting a recovery choice, or a newer file was seen.
    case readOnly
    case backupUnavailable
    /// The encoded document exceeds the read cap, so it could never be loaded back.
    case tooLarge
    case io(Int32)
}

public enum PersistenceLoadResult<Document: PersistedDocument>: Sendable {
    case missing
    case loaded(Document)
    /// The file can't be used; saving stays off until `recover(_:)`. `backup` is the last-known-good copy, if readable.
    case recovery(reason: PersistenceError, backup: Document?)
}

/// The two buttons of the recovery prompt.
public enum RecoveryChoice: Sendable { case recoverBackup, startEmpty }

/// The versioned envelope: size and nesting caps, version check, migration.
public enum PersistenceCodec {
    public static let byteLimit = 4_194_304
    public static let depthLimit = 128
    private enum Key: String, CodingKey { case schemaVersion }
    private struct Header: Decodable { var schemaVersion: Int }

    private struct Encoded<Document: PersistedDocument>: Encodable {
        var document: Document
        func encode(to encoder: any Encoder) throws {
            // The document's keyed container and this one share the same top-level JSON object.
            try document.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(Document.currentVersion, forKey: .schemaVersion)
        }
    }

    private struct Decoded<Document: PersistedDocument>: Decodable {
        var document: Document
        init(from decoder: any Decoder) throws {
            let version = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .schemaVersion)
            document = version == Document.currentVersion ? try Document(from: decoder) : try Document.migrate(from: version, decoder: decoder)
        }
    }

    public static func encode<Document: PersistedDocument>(_ document: Document) throws(PersistenceError) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Encoded(document: document)) else { throw .corrupt }
        guard data.count <= byteLimit else { throw .tooLarge }
        return data
    }

    public static func decode<Document: PersistedDocument>(_ type: Document.Type, from data: Data) throws(PersistenceError) -> Document {
        guard data.count <= byteLimit, nestingWithinLimit(data) else { throw .corrupt }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.schemaVersion >= 1 else { throw .corrupt }
        guard header.schemaVersion <= Document.currentVersion else { throw .newerVersion(header.schemaVersion) }
        guard let decoded = try? decoder.decode(Decoded<Document>.self, from: data) else { throw .corrupt }
        return decoded.document
    }

    /// Bounds recursive Codable work before decoding a file anyone with access to the folder could have edited.
    static func nestingWithinLimit(_ data: Data) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false; continue }
                switch byte {
                case UInt8(ascii: "\\"): escaped = true
                case UInt8(ascii: "\""): inString = false
                default: break
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1; if depth > depthLimit { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return true
    }
}

/// The single writer of one state file (NFR-RL04, MAC-12). Writes are owner-only and atomic; before each save the
/// previous good file becomes the backup. Saves carry a caller-assigned sequence and an older one never replaces a
/// newer one. Saving is off until `load()` has seen a usable (or missing) file, so nothing unread is overwritten.
public actor Persistence<Document: PersistedDocument> {
    public nonisolated let directory: URL
    public nonisolated let debounce: Duration
    public nonisolated var fileURL: URL { directory.appendingPathComponent(Document.file.fileName) }
    public nonisolated var backupURL: URL? { Document.file.backupName.map { directory.appendingPathComponent($0) } }

    /// The most recent failure of a debounced save; cleared by the next successful write.
    public private(set) var lastSaveError: PersistenceError?
    public var isWritable: Bool { writable && !sawNewerVersion }

    private var writable = false
    /// Sticky: once a newer file is seen, nothing is written to it for the rest of the session (AC5).
    private var sawNewerVersion = false
    /// Set by `recover(.startEmpty)` after the unreadable original was preserved, allowing one replacement of it.
    private var replaceUnreadable = false
    /// Set by a `.recovery` load; `recover(_:)` is refused otherwise, so Recover backup can't replace a good file.
    private var awaitingRecovery = false
    private var lastSequence: UInt64 = 0
    private var pending: (document: Document, sequence: UInt64)?
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let beforeReplace: @Sendable (URL) throws -> Void

    /// `sleep` drives the debounce and `beforeReplace` runs between a temporary's fsync and its rename; tests inject both.
    public init(
        directory: URL, debounce: Duration = .milliseconds(300), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        beforeReplace: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.directory = directory; self.debounce = debounce; self.sleep = sleep; self.beforeReplace = beforeReplace
    }

    public func load() -> PersistenceLoadResult<Document> {
        replaceUnreadable = false; awaitingRecovery = false
        do {
            guard let data = try read(fileURL) else { writable = true; return .missing }
            let document = try PersistenceCodec.decode(Document.self, from: data)
            writable = true
            return .loaded(document)
        } catch {
            writable = false; awaitingRecovery = true
            if case .newerVersion = error { sawNewerVersion = true }
            return .recovery(reason: error, backup: readBackup())
        }
    }

    /// The user's answer to a recovery prompt. The unreadable original is copied to `<name>.corrupt.<UUID>.json`
    /// before anything else is written. `.recoverBackup` returns the backup, now also the current file; `.startEmpty`
    /// returns nil and the next save replaces the original. Without a pending recovery, or for a newer-version file,
    /// it throws `.readOnly`.
    @discardableResult
    public func recover(_ choice: RecoveryChoice) throws(PersistenceError) -> Document? {
        guard !sawNewerVersion, awaitingRecovery else { throw .readOnly }
        var restored: (document: Document, data: Data)?
        if choice == .recoverBackup {
            guard let url = backupURL, let data = try? read(url), let document = try? PersistenceCodec.decode(Document.self, from: data) else {
                throw .backupUnavailable
            }
            restored = (document, data)
        }
        try prepareDirectory()
        let preserved = directory.appendingPathComponent(Document.file.corruptName(UUID()))
        do throws(PersistenceError) {
            if let original = try read(fileURL) {
                // Re-check: another process may have replaced the file with a newer version since `load()`.
                if case .failure(.newerVersion) = decodeResult(original) {
                    sawNewerVersion = true; throw .readOnly
                }
                try write(original, to: preserved)
            }
        } catch .corrupt {
            // Oversized or not a regular file, so it can't be copied within the read cap: keep it under a second name
            // (a hard link, never following a symlink) so the replacement below leaves the original intact.
            guard linkat(AT_FDCWD, fileURL.path, AT_FDCWD, preserved.path, 0) == 0 else { throw .io(errno) }
            _ = chmod(preserved.path, 0o600)
        }
        if let restored {
            try write(restored.data, to: fileURL)
            writable = true; replaceUnreadable = false; awaitingRecovery = false
            return restored.document
        }
        writable = true; replaceUnreadable = true; awaitingRecovery = false
        return nil
    }

    /// Writes now. Returns false when a save with a higher sequence has already been written.
    @discardableResult
    public func save(_ document: Document, sequence: UInt64) throws(PersistenceError) -> Bool {
        // An immediate save supersedes any older debounced one.
        if let pending, pending.sequence <= sequence { self.pending = nil }
        guard isWritable else { throw .readOnly }
        guard sequence >= lastSequence else { return false }
        let data = try PersistenceCodec.encode(document)
        try prepareDirectory()
        let previous: Data?
        // An oversized or non-regular original that `recover(.startEmpty)` preserved may be replaced unread.
        do throws(PersistenceError) { previous = try read(fileURL) } catch .corrupt where replaceUnreadable { previous = nil }
        if let previous {
            switch decodeResult(previous) {
            case .success:
                if let backupURL { try write(previous, to: backupURL) }
            case .failure(.newerVersion):
                // A newer Keel wrote the file while this one was running.
                sawNewerVersion = true; throw .readOnly
            case .failure:
                // The file went bad after `load()`; it is replaced only after an explicit recovery preserved it.
                guard replaceUnreadable else { writable = false; throw .readOnly }
            }
        }
        try write(data, to: fileURL)
        replaceUnreadable = false; lastSequence = sequence; lastSaveError = nil
        return true
    }

    /// Debounced save: the latest document is written once no newer one arrives for `debounce`.
    /// A document older than the pending or last written one is ignored.
    public func scheduleSave(_ document: Document, sequence: UInt64) {
        guard sequence >= lastSequence, sequence >= pending?.sequence ?? 0 else { return }
        pending = (document, sequence)
        generation &+= 1
        let token = generation, sleep = sleep, debounce = debounce
        debounceTask?.cancel()
        // The task inherits this actor's isolation, so the flush runs on it after the sleep.
        debounceTask = Task {
            do { try await sleep(debounce) } catch { return }
            self.flushScheduled(token)
        }
    }

    /// Writes the pending debounced save immediately (quit, or before a dependent write).
    public func flush() throws(PersistenceError) {
        debounceTask?.cancel(); debounceTask = nil
        guard let pending else { return }
        self.pending = nil
        do { try save(pending.document, sequence: pending.sequence) } catch {
            // Keep it so a later flush (e.g. on quit) can retry a transient failure, unless something newer arrived.
            if self.pending == nil { self.pending = pending }
            lastSaveError = error; throw error
        }
    }

    /// Waits for the scheduled debounce, if any, to finish; for tests.
    func settle() async { await debounceTask?.value }

    private func flushScheduled(_ token: UInt64) {
        // A newer `scheduleSave` restarted the timer; its own task writes.
        guard token == generation else { return }
        try? flush()
    }

    private func decodeResult(_ data: Data) -> Result<Document, PersistenceError> {
        Result { () throws(PersistenceError) in try PersistenceCodec.decode(Document.self, from: data) }
    }

    private func readBackup() -> Document? {
        guard let url = backupURL, let data = try? read(url) else { return nil }
        return try? PersistenceCodec.decode(Document.self, from: data)
    }

    private func read(_ url: URL) throws(PersistenceError) -> Data? {
        do { return try OwnerOnlyStorage.read(url, limit: PersistenceCodec.byteLimit) } catch {
            switch error {
            case .corrupt: throw .corrupt
            case .io(let code): throw .io(code)
            }
        }
    }

    /// Refuses a symlink at the target: the rename would replace the link, but its presence means someone redirected our state.
    private func write(_ data: Data, to target: URL) throws(PersistenceError) {
        var info = stat()
        if lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw .io(ELOOP) }
        do { try OwnerOnlyStorage.atomicWrite(data, to: target, temporaryPrefix: Document.file.temporaryPrefix, beforeReplace: beforeReplace) } catch {
            if case OwnerOnlyStorageError.io(let code) = error { throw .io(code) }
            throw .io(EIO)
        }
    }

    /// The state folder must be a real 0700 folder owned by this user (MAC-12).
    private func prepareDirectory() throws(PersistenceError) {
        do { try StateLocation.prepare(directory) } catch {
            switch error as? StateLocation.Failure {
            case .symlink: throw .io(ELOOP)
            case .notADirectory: throw .io(ENOTDIR)
            case .notOwned: throw .io(EPERM)
            case nil: throw .io((error as NSError).domain == NSPOSIXErrorDomain ? Int32((error as NSError).code) : EIO)
            }
        }
    }
}

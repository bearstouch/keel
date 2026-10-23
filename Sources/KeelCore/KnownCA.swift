import CryptoKit
import Darwin
import Foundation
import KeelRESP

/// The SHA-256 of a CA file's bytes (FR-CN04). Stored as 64 lowercase hex digits; shown as colon-separated pairs.
public struct CAFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hex: String

    public init(of data: Data) { hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Nil unless `hex` is exactly 64 lowercase hex digits, so a hand-edited file can't carry a malformed fingerprint.
    public init?(hex: String) {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        self.hex = hex
    }

    /// `AB:CD:…`, the form `openssl … -fingerprint -sha256` prints.
    public var description: String {
        let digits = Array(hex.uppercased())
        return stride(from: 0, to: digits.count, by: 2).map { String(digits[$0..<$0 + 2]) }.joined(separator: ":")
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = CAFingerprint(hex: text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a SHA-256 fingerprint")) }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// `known-ca.json`: the fingerprint of the CA file each profile last trusted.
public struct KnownCADocument: PersistedDocument, Equatable {
    public static let file = PersistedFile.knownCA
    public static let currentVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: CAFingerprint
    }

    /// Keyed by profile UUID string (a JSON object needs string keys).
    public var profiles: [String: Entry] = [:]
    /// Set once earlier records were lost (an unreadable file was replaced). From then on a profile without a record
    /// is asked about rather than trusted on first use, since its old fingerprint may have been among the lost ones.
    public var recordsLost = false

    public init(profiles: [String: Entry] = [:], recordsLost: Bool = false) { self.profiles = profiles; self.recordsLost = recordsLost }

    private enum CodingKeys: String, CodingKey { case profiles, recordsLost }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([String: Entry].self, forKey: .profiles)
        recordsLost = try container.decodeIfPresent(Bool.self, forKey: .recordsLost) ?? false
    }
}

/// Why a CA file couldn't be used. Every case names the path, so the message says which file to fix (AC3).
public enum KnownCAError: Error, Equatable, Sendable {
    case missing(path: String)
    /// Permission denied, not a regular file (`EISDIR`, `EFTYPE`) or over `CAFile.byteLimit` (`EFBIG`).
    case unreadable(path: String, code: Int32)
    case invalidBundle(path: String, TLSBundleError)
    /// The user declined a changed file; nothing was sent to the server.
    case declined(path: String)
}

/// Reading a user-selected CA bundle. Unlike state files, it may be a symlink (Homebrew and system bundles often are).
public enum CAFile {
    public static let byteLimit = 4_194_304

    public static func read(_ path: String) throws(KnownCAError) -> Data {
        // `O_NONBLOCK` keeps a FIFO from hanging the connect; the type check below refuses it anyway.
        // `open` follows symlinks on purpose: the user picked this path, and trust is pinned to the bytes, not the inode.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            // A missing parent folder (`ENOTDIR`) is still "the file isn't there" to the user.
            throw code == ENOENT || code == ENOTDIR ? .missing(path: path) : .unreadable(path: path, code: code)
        }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable(path: path, code: errno) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFDIR: throw .unreadable(path: path, code: EISDIR)
        default: throw .unreadable(path: path, code: EFTYPE)
        }
        // Checked before reading so a huge file is refused without buffering it.
        guard info.st_size <= byteLimit else { throw .unreadable(path: path, code: EFBIG) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw .unreadable(path: path, code: errno) }
            result.append(contentsOf: buffer.prefix(count))
            // The file may grow after `fstat`.
            guard result.count <= byteLimit else { throw .unreadable(path: path, code: EFBIG) }
        }
    }
}

/// A CA file whose contents differ from the fingerprint on record. The connect waits for the user to compare
/// `previous` and `current` and accept; `anchors` come from the same bytes that were hashed, so what is accepted is
/// exactly what gets trusted even if the file changes again while the prompt is open.
public struct CAChange: Sendable, Equatable {
    public let profile: UUID
    public let path: String
    /// Nil when the record was lost (see `KnownCADocument.recordsLost`).
    public let previous: CAFingerprint?
    public let current: CAFingerprint
    let anchors: [Data]
}

public enum CATrust: Sendable, Equatable {
    /// Anchors for `TLSConfiguration.anchorCertificates`.
    case trusted(anchors: [Data])
    case changed(CAChange)
}

/// The single owner of `known-ca.json` (FR-CN04). Before a TLS connect with a custom CA, `check` reads the file,
/// parses it, and compares its SHA-256 with the one recorded for the profile: first use records it, a match trusts it,
/// a difference returns a `CAChange` that only `accept` turns into anchors. Records survive failed saves in memory,
/// and a store that can't be saved only asks again next launch; it never trusts a file silently.
public actor KnownCAStore {
    private let persistence: Persistence<KnownCADocument>
    private let readFile: @Sendable (String) throws(KnownCAError) -> Data
    private var document: KnownCADocument?
    /// Shared by calls that arrive while the file is being loaded, so it is loaded (and recovered) once.
    private var loading: Task<KnownCADocument, Never>?
    private var sequence: UInt64 = 0
    /// The most recent failure to save a record; the record still holds for this session.
    public private(set) var lastSaveError: PersistenceError?

    public init(directory: URL, readFile: @escaping @Sendable (String) throws(KnownCAError) -> Data = { path throws(KnownCAError) in try CAFile.read(path) }) {
        persistence = Persistence(directory: directory); self.readFile = readFile
    }

    /// Reads and checks `path` for `profile`. Throws when the file is missing, unreadable or has no usable certificate;
    /// nothing is recorded then.
    public func check(profile: UUID, caFile path: String) async throws(KnownCAError) -> CATrust {
        let data = try readFile(path)
        let anchors: [Data]
        do { anchors = try TLSConfiguration.certificates(fromPEM: data) } catch { throw .invalidBundle(path: path, error) }
        let current = CAFingerprint(of: data)
        let document = await loaded()
        switch document.profiles[profile.uuidString] {
        case let entry? where entry.path == path:
            guard entry.sha256 == current else { return .changed(CAChange(profile: profile, path: path, previous: entry.sha256, current: current, anchors: anchors)) }
            return .trusted(anchors: anchors)
        case _ where document.recordsLost:
            // A record may have existed: ask instead of trusting on first use.
            return .changed(CAChange(profile: profile, path: path, previous: nil, current: current, anchors: anchors))
        default:
            // First use, or the profile now points at a different file (an explicit choice in the editor).
            await update { $0.profiles[profile.uuidString] = .init(path: path, sha256: current) }
            return .trusted(anchors: anchors)
        }
    }

    /// The user accepted `change`: its fingerprint becomes the record and its anchors are returned for the connect.
    public func accept(_ change: CAChange) async -> [Data] {
        // Load first so the update starts from the stored records instead of replacing them with an empty document.
        _ = await loaded()
        await update { $0.profiles[change.profile.uuidString] = .init(path: change.path, sha256: change.current) }
        return change.anchors
    }

    /// `check`, then `confirm` for a changed file. Declining throws `.declined` before any connection is opened.
    public func anchors(profile: UUID, caFile path: String, confirm: @Sendable (CAChange) async -> Bool) async throws(KnownCAError) -> [Data] {
        switch try await check(profile: profile, caFile: path) {
        case .trusted(let anchors): return anchors
        case .changed(let change):
            guard await confirm(change) else { throw .declined(path: path) }
            return await accept(change)
        }
    }

    /// Drops the record of a deleted profile, or one that no longer uses a custom CA.
    public func forget(profile: UUID) async {
        guard await loaded().profiles[profile.uuidString] != nil else { return }
        await update { $0.profiles[profile.uuidString] = nil }
    }

    /// The recorded fingerprint, if any; for the profile editor and tests.
    public func fingerprint(profile: UUID) async -> CAFingerprint? { await loaded().profiles[profile.uuidString]?.sha256 }

    /// Loads the file once. An unreadable file is preserved as `known-ca.corrupt.<UUID>.json` and replaced by an empty
    /// one marked `recordsLost`; a newer or otherwise unrecoverable file leaves an in-memory store with the same mark.
    private func loaded() async -> KnownCADocument {
        if let document { return document }
        let persistence = persistence
        // Every waiter installs the result and returns the live document: returning the task's value could hand a
        // waiter a snapshot without records added since (trusting a swapped file as first use), and a waiter resumed
        // before the first caller would otherwise update from an empty document and drop every record.
        let task =
            loading
            ?? Task { () -> KnownCADocument in
                switch await persistence.load() {
                case .missing: return KnownCADocument()
                case .loaded(let stored): return stored
                case .recovery:
                    // Saving stays off unless the original was preserved; then the first save marks the loss on disk.
                    _ = try? await persistence.recover(.startEmpty)
                    return KnownCADocument(recordsLost: true)
                }
            }
        loading = task
        let result = await task.value
        // Another caller awaiting the same task may already have installed it (and saved the loss mark).
        if document == nil {
            document = result
            if result.recordsLost { await save(result) }
        }
        return document ?? result
    }

    /// Applies `change` to the in-memory document synchronously (no lost update across suspension points), then
    /// writes a snapshot. The sequence keeps an older snapshot from replacing a newer one.
    private func update(_ change: (inout KnownCADocument) -> Void) async {
        var updated = document ?? KnownCADocument()
        change(&updated)
        document = updated
        await save(updated)
    }

    private func save(_ snapshot: KnownCADocument) async {
        sequence += 1
        do { try await persistence.save(snapshot, sequence: sequence); lastSaveError = nil } catch { lastSaveError = error }
    }
}

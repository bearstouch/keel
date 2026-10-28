import Foundation

/// A profiles-and-folders export file (FR-CN14, INT-12): versioned JSON with only the editor's settings. No secret
/// and no secret flag (`hasPassword`, `hasTLSSecret`) is ever part of it; revisions are store-local and stay out too.
/// IDs are kept, so a re-import recognises the records it already has; an imported profile is saved under a new ID
/// and remembers the file's (`ConnectionProfile.importedFrom`).
public struct ProfileExport: Equatable, Sendable {
    public static let format = "keel-profiles"
    public static let currentVersion = 1
    /// The same cap as the state files: an import can never grow `connections.json` past what Keel will read back.
    public static let byteLimit = PersistenceCodec.byteLimit

    public struct Folder: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public struct Profile: Codable, Equatable, Sendable {
        public var id: UUID
        /// nil: top level. Always one of the file's own folders.
        public var folderID: UUID?
        public var settings: ConnectionSettings
        public init(id: UUID, folderID: UUID? = nil, settings: ConnectionSettings) { self.id = id; self.folderID = folderID; self.settings = settings }
    }

    /// In display order, like `connections.json`.
    public var folders: [Folder]
    public var profiles: [Profile]

    public init(folders: [Folder] = [], profiles: [Profile] = []) { self.folders = folders; self.profiles = profiles }

    /// Everything in `document`, in its order, without secrets or flags.
    public init(_ document: ConnectionsDocument) {
        folders = document.folders.map { Folder(id: $0.id, name: $0.name) }
        profiles = document.profiles.map { Profile(id: $0.id, folderID: $0.folderID, settings: $0.settings) }
    }

    /// The same checks `connections.json` gets on load, since an export can come from anywhere: unique IDs, folder
    /// references inside the file, valid names and settings. The first bad field is reported.
    public func validated() throws(ProfileImportError) -> ProfileExport {
        let folderIDs = Set(folders.map(\.id))
        // A repeated ID would make one record silently overwrite another.
        guard folderIDs.count == folders.count, Set(profiles.map(\.id)).count == profiles.count else { throw .invalid(nil) }
        for folder in folders where !ConnectionsDocument.isFolderName(folder.name) { throw .invalid(.folder) }
        for profile in profiles {
            if let folderID = profile.folderID, !folderIDs.contains(folderID) { throw .invalid(.folder) }
            do { _ = try profile.settings.validated() } catch {
                guard case .invalid(let field) = error else { throw .invalid(nil) }
                throw .invalid(field)
            }
        }
        return self
    }

    /// The saved profile an imported record with `id` collides with: the one with that ID, else one imported under it.
    static func match(_ id: UUID, in profiles: [ConnectionProfile]) -> Int? {
        profiles.firstIndex { $0.id == id } ?? profiles.firstIndex { $0.importedFrom == id }
    }

    // MARK: File format

    private struct Header: Decodable {
        var format: String?
        var schemaVersion: Int?
    }

    private struct File: Codable {
        var format: String
        var schemaVersion: Int
        var folders: [Folder]
        var profiles: [Profile]
    }

    /// Pretty-printed with sorted keys, so two exports of the same profiles are byte-identical.
    public func encoded() throws(ProfileImportError) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(format: Self.format, schemaVersion: Self.currentVersion, folders: folders, profiles: profiles)) else { throw .invalid(nil) }
        guard data.count <= Self.byteLimit else { throw .tooLarge }
        return data
    }

    /// Reads an export file. The header is checked before the body, so a newer file is refused by its version and
    /// never by a decoding error of fields this Keel doesn't know.
    public static func decode(_ data: Data) throws(ProfileImportError) -> ProfileExport {
        guard data.count <= byteLimit else { throw .tooLarge }
        guard PersistenceCodec.nestingWithinLimit(data), let header = try? JSONDecoder().decode(Header.self, from: data) else { throw .notAnExport }
        guard header.format == format, let version = header.schemaVersion, version >= 1 else { throw .notAnExport }
        guard version <= currentVersion else { throw .newerVersion(version) }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw .invalid(nil) }
        return try ProfileExport(folders: file.folders, profiles: file.profiles).validated()
    }
}

/// Why an export file can't be read. Nothing is imported in any of these cases.
public enum ProfileImportError: Error, Equatable, Sendable {
    /// Not JSON, or not a Keel connections export.
    case notAnExport
    /// Written by a newer Keel; this one doesn't know its format.
    case newerVersion(Int)
    case tooLarge
    /// A record is malformed or fails validation; `field` names the first bad one when known.
    case invalid(ProfileField?)

    /// One line for the import alert.
    public var message: String {
        switch self {
        case .notAnExport: "This file isn't a Keel connections export."
        case .newerVersion(let version): "This file was exported by a newer version of Keel (format \(version)). Update Keel to import it."
        case .tooLarge: "This file is too large to import."
        case .invalid(let field): "This export is damaged" + (field.map { " (\($0.rawValue))" } ?? "") + ", so nothing was imported."
        }
    }
}

/// What happens to an imported record whose ID is already saved (FR-CN14). There is no default: the caller picks one.
public enum ProfileImportPolicy: String, CaseIterable, Sendable {
    /// Leave the saved profile or folder as it is.
    case skip
    /// Overwrite the saved settings, folder and folder name with the imported ones; the usual connection-revision
    /// rule removes a saved password when the connection changed.
    case replace
    /// Add the imported profile as a new one, named "<name> (imported)". Folders are shared, not duplicated.
    case keepBoth
}

/// The import preview: what the file holds and which of its records are already saved.
public struct ProfileImportPreview: Equatable, Sendable {
    public var profileCount: Int
    public var folderCount: Int
    /// Names of the saved profiles and folders an import would collide with, in file order.
    public var conflictingProfiles: [String]
    public var conflictingFolders: [String]

    public var hasConflicts: Bool { !conflictingProfiles.isEmpty || !conflictingFolders.isEmpty }
}

public struct ProfileImportResult: Equatable, Sendable {
    public var added = 0
    public var replaced = 0
    /// Conflicts left alone, and replacements that would have changed nothing.
    public var skipped = 0
    public var foldersAdded = 0
    /// Saved folders Replace renamed to the file's name.
    public var foldersRenamed = 0

    public init(added: Int = 0, replaced: Int = 0, skipped: Int = 0, foldersAdded: Int = 0, foldersRenamed: Int = 0) {
        self.added = added; self.replaced = replaced; self.skipped = skipped; self.foldersAdded = foldersAdded; self.foldersRenamed = foldersRenamed
    }
}

extension ProfileStore {
    /// The current profiles and folders as an export file's contents.
    public func export() -> ProfileExport { ProfileExport(document) }

    public func previewImport(_ export: ProfileExport) -> ProfileImportPreview {
        let profiles = document.profiles
        let folders = Dictionary(uniqueKeysWithValues: document.folders.map { ($0.id, $0.name) })
        return ProfileImportPreview(
            profileCount: export.profiles.count, folderCount: export.folders.count, conflictingProfiles: export.profiles.compactMap { ProfileExport.match($0.id, in: profiles).map { profiles[$0].settings.name } },
            conflictingFolders: export.folders.compactMap { folders[$0.id] })
    }
}

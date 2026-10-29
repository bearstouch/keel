import Foundation
import KeelSSH

public enum ProfileStoreError: Error, Equatable, Sendable {
    case invalid(ProfileField)
    case notFound
    /// The record changed since the editor loaded it (`CONFLICT`).
    case conflict(expected: UInt64, actual: UInt64)
    /// Not loaded, awaiting a recovery choice, or `connections.json` was written by a newer Keel.
    case readOnly
    /// The metadata write failed; the previous profiles and Keychain items are back in place.
    case persistence(PersistenceError)
    /// The Keychain refused a read or write; nothing changed.
    case secretStore(SecretStoreError)
    /// An import's file failed validation; nothing changed.
    case invalidImport(ProfileImportError)
}

/// What to do with a profile's saved password in `update`.
public enum PasswordChange: Equatable, Sendable {
    /// Keep it, unless the connection changed (then it is removed).
    case keep
    case set(Data)
    case remove
}

/// What to do with a profile's client identity (`Keel TLS`) in `update` (FR-CN03).
public enum TLSIdentityChange: Equatable, Sendable {
    case keep
    /// Saves an import from `TLSIdentityImporter`, replacing the profile's previous identity.
    case set(ImportedTLSIdentity)
    case remove
}

/// The single owner of `connections.json` and of the profiles' Keychain items (FR-CN01, FR-CN02, FR-CN09).
///
/// Every mutation validates first, then writes the Keychain, then the metadata; a failed metadata write restores
/// the previous Keychain values, so `hasPassword` and the Keychain never disagree. Mutations are serialized across
/// the `Persistence` suspension, and a record only changes in memory once it is on disk. Each change stamps the
/// record with the next store revision; editors pass the revision they started from and get `.conflict` when stale.
/// A change to host, port, username, TLS server name or tunnel advances the connection revision and removes the
/// saved password, so it is never offered to a different server. A profile tunneled through a saved SSH host also
/// binds its password to what that host connects to (`SavedHostBinding`): re-pointing the host refuses and removes it.
/// A client identity Keel's import added to the Keychain is removed once the last profile using it lets it go.
public actor ProfileStore {
    public private(set) var document = ConnectionsDocument() {
        didSet { for observer in observers.values { observer.yield(document) } }
    }
    /// False until `load()` sees a usable or missing file, while awaiting recovery, and for a newer file.
    public private(set) var isWritable = false

    private let persistence: Persistence<ConnectionsDocument>
    private let secrets: any SecretStore
    private let makeID: @Sendable () -> UUID
    /// The saved SSH host a `.savedHost` tunnel names, as `HostLibrary` holds it now; nil when it is gone.
    private let resolveSavedHost: @Sendable (UUID) async -> SavedHost?
    /// Removes a client identity (certificate and key) from the Keychain: `TLSIdentityImporter.removeIdentity`.
    private let removeTLSIdentity: @Sendable (Data) -> Void
    /// The backup offered by the last `.recovery` load; for a newer file it can only be used in memory.
    private var recoveryBackup: ConnectionsDocument?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// `changes()` subscribers; each sees only the newest document, so a slow view never queues stale copies.
    private var observers: [UUID: AsyncStream<ConnectionsDocument>.Continuation] = [:]

    public static let passwordByteLimit = 4096

    public init(
        persistence: Persistence<ConnectionsDocument>, secrets: any SecretStore, makeID: @escaping @Sendable () -> UUID = { UUID() },
        resolveSavedHost: @escaping @Sendable (UUID) async -> SavedHost? = { _ in nil }, removeTLSIdentity: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.persistence = persistence; self.secrets = secrets; self.makeID = makeID; self.resolveSavedHost = resolveSavedHost
        self.removeTLSIdentity = removeTLSIdentity
    }

    public init(
        directory: URL, secrets: any SecretStore = KeychainSecretStore(), resolveSavedHost: @escaping @Sendable (UUID) async -> SavedHost? = { _ in nil },
        removeTLSIdentity: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.init(persistence: Persistence(directory: directory), secrets: secrets, resolveSavedHost: resolveSavedHost, removeTLSIdentity: removeTLSIdentity)
    }

    public enum LoadOutcome: Equatable, Sendable {
        case ready
        /// Show **Recover backup** / **Start empty**; the store stays empty and read-only until `recover(_:)`.
        case recovery(reason: PersistenceError, backupAvailable: Bool)
    }

    // MARK: Reading

    public var profiles: [ConnectionProfile] { document.profiles }
    public var folders: [ProfileFolder] { document.folders }
    public var labels: [ProfileLabel] { document.labels }
    public func profile(_ id: UUID) -> ConnectionProfile? { document.profiles.first { $0.id == id } }
    public func isProduction(_ profile: ConnectionProfile) -> Bool { document.label(profile.settings.label).treatAsProduction }

    /// The saved password for a connect, bound to the connection revision the caller resolved the profile at: nil
    /// when the profile is gone, has no password or its connection changed since. It waits for an in-flight mutation:
    /// those write the Keychain before the metadata, so a new connection's password must not reach the old one.
    /// Through a saved SSH host it is also nil when the host is gone or now connects elsewhere than the password was
    /// saved for; the stale password is then removed, so the editor stops offering it.
    public func password(profileID: UUID, connectionRevision: UInt64) async throws(ProfileStoreError) -> Data? {
        await acquire(); defer { release() }
        guard let profile = profile(profileID), profile.connectionRevision == connectionRevision, profile.hasPassword else { return nil }
        if case .savedHost(let hostID) = profile.settings.tunnel {
            guard let host = await resolveSavedHost(hostID) else { return nil }
            let binding = SavedHostBinding(host)
            if let bound = profile.savedHostBinding {
                guard bound == binding else { await rebind(profileID, nil); return nil }
            } else {
                // Written before Keel recorded the binding: trust the host as it is now, and bind to it from here on.
                await rebind(profileID, binding)
            }
        }
        do { return try secrets.read(.password, profileID: profileID) } catch { throw .secretStore(error) }
    }

    /// The current document, then every document the store publishes (load, recovery and each committed change), so
    /// the sidebar follows edits made by the sheet, an import or another view. Ends when the caller stops iterating.
    public func changes() -> AsyncStream<ConnectionsDocument> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionsDocument.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(document)
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Loading and recovery

    public func load() async -> LoadOutcome {
        await acquire(); defer { release() }
        recoveryBackup = nil
        switch await persistence.load() {
        case .missing: document = ConnectionsDocument(); isWritable = true; return .ready
        case .loaded(let stored): document = stored; isWritable = true; return .ready
        case .recovery(let reason, let backup):
            document = ConnectionsDocument(); isWritable = false; recoveryBackup = backup
            return .recovery(reason: reason, backupAvailable: backup != nil)
        }
    }

    /// The user's recovery choice. For a newer-version file, **Recover backup** shows the backup read-only for this
    /// session (the newer file is never overwritten); **Start empty** is refused.
    public func recover(_ choice: RecoveryChoice) async throws(ProfileStoreError) {
        await acquire(); defer { release() }
        do {
            document = try await persistence.recover(choice) ?? ConnectionsDocument()
            isWritable = true; recoveryBackup = nil
        } catch .readOnly where choice == .recoverBackup && recoveryBackup != nil {
            document = recoveryBackup ?? ConnectionsDocument(); isWritable = false
        } catch {
            throw Self.storeError(error)
        }
    }

    // MARK: Profiles

    /// Adds a profile at the end of `folderID` (or the top level). The password and client identity go to the
    /// Keychain first.
    public func create(_ settings: ConnectionSettings, folderID: UUID? = nil, password: Data? = nil, identity: ImportedTLSIdentity? = nil) async throws(ProfileStoreError)
        -> ConnectionProfile
    {
        await acquire(); defer { release() }
        let valid = try settings.validated()
        try requireFolder(folderID)
        if let password { try Self.validate(password) }
        let binding = password == nil ? nil : try await savedHostBinding(valid)
        var next = try nextDocument()
        var profile = ConnectionProfile(id: makeID(), settings: valid, folderID: folderID, revision: next.revision, hasPassword: password != nil, savedHostBinding: binding)
        var undo = Undo()
        if let password { try stage(.password, password, profileID: profile.id, existed: false, undo: &undo) }
        if let identity { _ = try stageIdentity(.set(identity), on: &profile, previous: nil, undo: &undo) }
        next.profiles.insert(profile, at: Self.insertionIndex(in: next.profiles, folderID: folderID, position: nil))
        try await commit(next, undo: undo)
        return profile
    }

    /// Saves the editor's settings. Renaming or relabeling keeps the connection revision and the password; a new
    /// connection advances the revision and removes the password unless `password` sets a new one. An unchanged
    /// save keeps the revision, so it doesn't remove the saved password. `identity` sets or removes the client identity;
    /// the one it replaces leaves the Keychain once saved, if Keel's import added it and no other profile uses it.
    public func update(
        _ id: UUID, _ settings: ConnectionSettings, password: PasswordChange = .keep, identity: TLSIdentityChange = .keep, expectedRevision: UInt64
    ) async throws(ProfileStoreError) -> ConnectionProfile {
        await acquire(); defer { release() }
        let (index, current) = try locate(id, expectedRevision: expectedRevision)
        let valid = try settings.validated()
        if case .set(let value) = password { try Self.validate(value) }
        let connectionChanged = valid.connectionKey != current.settings.connectionKey || valid.weakensTransport(from: current.settings)
        // nil: leave the item alone; .some(nil): remove it; .some(data): write it.
        let secretChange: Data??
        switch password {
        case .set(let value): secretChange = .some(value)
        case .remove: secretChange = current.hasPassword ? .some(nil) : nil
        case .keep: secretChange = connectionChanged && current.hasPassword ? .some(nil) : nil
        }
        let identityChanges = identity != .keep && (identity != .remove || current.hasTLSSecret)
        guard valid != current.settings || secretChange != nil || identityChanges else { return current }
        // A new password binds to the saved host as it is now; a kept one keeps the binding it was saved with.
        let binding: SavedHostBinding?
        switch secretChange {
        case .some(.some): binding = try await savedHostBinding(valid)
        case .some(.none): binding = nil
        case .none: binding = current.savedHostBinding
        }
        var next = try nextDocument()
        var profile = current
        profile.settings = valid; profile.revision = next.revision
        if connectionChanged { profile.connectionRevision = next.revision }
        if let secretChange { profile.hasPassword = secretChange != nil }
        profile.savedHostBinding = binding
        var undo = Undo()
        if let secretChange { try stage(.password, secretChange, profileID: id, existed: current.hasPassword, undo: &undo) }
        var released: TLSIdentitySecret?
        if identityChanges {
            let previous: TLSIdentitySecret?
            do { previous = try identitySecret(current) } catch { undo.run(); throw error }
            released = try stageIdentity(identity, on: &profile, previous: previous, undo: &undo)
        }
        next.profiles[index] = profile
        try await commit(next, undo: undo)
        release(released)
        return profile
    }

    /// A copy right after the original, named "<name> copy", with copies of its Keychain items.
    public func duplicate(_ id: UUID) async throws(ProfileStoreError) -> ConnectionProfile {
        await acquire(); defer { release() }
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let source = document.profiles[index]
        var settings = source.settings
        settings.name = String((source.settings.name + " copy").prefix(ConnectionSettings.nameLimit))
        var next = try nextDocument()
        let copy = ConnectionProfile(
            id: makeID(), settings: settings, folderID: source.folderID, revision: next.revision, hasPassword: source.hasPassword, hasTLSSecret: source.hasTLSSecret,
            savedHostBinding: source.savedHostBinding)
        next.profiles.insert(copy, at: index + 1)
        var undo = Undo()
        for (secret, flag) in [(ProfileSecret.password, \ConnectionProfile.hasPassword), (.tls, \.hasTLSSecret)] where source[keyPath: flag] {
            let value: Data?
            do { value = try secrets.read(secret, profileID: id) } catch {
                undo.run(); throw .secretStore(error)
            }
            // The flag said the item exists but it's gone: the copy simply has none.
            guard let value else {
                next.profiles[index + 1][keyPath: flag] = false
                if secret == .password { next.profiles[index + 1].savedHostBinding = nil }
                continue
            }
            try stage(secret, value, profileID: copy.id, existed: false, undo: &undo)
        }
        try await commit(next, undo: undo)
        return next.profiles[index + 1]
    }

    /// Removes the profile and its `Keel Connection` and `Keel TLS` items. The Keychain items go first and come back
    /// if the metadata can't be written. The client identity itself (certificate and key) then leaves the Keychain
    /// only if Keel's import added it and no other profile uses it.
    public func delete(_ id: UUID, expectedRevision: UInt64? = nil) async throws(ProfileStoreError) {
        await acquire(); defer { release() }
        guard let current = profile(id) else { throw .notFound }
        if let expectedRevision, current.revision != expectedRevision { throw .conflict(expected: expectedRevision, actual: current.revision) }
        var next = try nextDocument()
        next.profiles.removeAll { $0.id == id }
        let previous = try identitySecret(current)
        var undo = Undo()
        // Always cleared, even without a flag, so no orphaned item outlives its profile.
        for secret in ProfileSecret.allCases { try stage(secret, nil, profileID: id, existed: true, undo: &undo) }
        try await commit(next, undo: undo)
        release(previous)
    }

    /// Moves a profile to `folderID` (nil: top level) at `position` among that folder's profiles (nil: the end).
    public func move(_ id: UUID, toFolder folderID: UUID?, position: Int? = nil, expectedRevision: UInt64) async throws(ProfileStoreError) -> ConnectionProfile {
        await acquire(); defer { release() }
        let (index, current) = try locate(id, expectedRevision: expectedRevision)
        try requireFolder(folderID)
        var next = try nextDocument()
        next.profiles.remove(at: index)
        var profile = current
        profile.folderID = folderID; profile.revision = next.revision
        next.profiles.insert(profile, at: Self.insertionIndex(in: next.profiles, folderID: folderID, position: position))
        try await commit(next, undo: Undo())
        return profile
    }

    // MARK: Folders

    public func createFolder(named name: String) async throws(ProfileStoreError) -> ProfileFolder {
        await acquire(); defer { release() }
        guard ConnectionsDocument.isFolderName(name) else { throw .invalid(.folder) }
        var next = try nextDocument()
        let folder = ProfileFolder(id: makeID(), name: name, revision: next.revision)
        next.folders.append(folder)
        try await commit(next, undo: Undo())
        return folder
    }

    public func renameFolder(_ id: UUID, to name: String, expectedRevision: UInt64) async throws(ProfileStoreError) -> ProfileFolder {
        guard ConnectionsDocument.isFolderName(name) else { throw .invalid(.folder) }
        return try await updateFolder(id, expectedRevision: expectedRevision) { $0.name = name }
    }

    /// Collapse state is a view preference, so it doesn't conflict with a stale editor.
    public func setFolderCollapsed(_ id: UUID, _ collapsed: Bool) async throws(ProfileStoreError) -> ProfileFolder {
        try await updateFolder(id, expectedRevision: nil) { $0.collapsed = collapsed }
    }

    public func moveFolder(_ id: UUID, to position: Int) async throws(ProfileStoreError) {
        await acquire(); defer { release() }
        guard let index = document.folders.firstIndex(where: { $0.id == id }) else { throw .notFound }
        var next = try nextDocument()
        let folder = next.folders.remove(at: index)
        next.folders.insert(folder, at: min(max(position, 0), next.folders.count))
        try await commit(next, undo: Undo())
    }

    /// Deletes the folder; its profiles move to the top level, keeping their order. Nothing else is removed.
    public func deleteFolder(_ id: UUID, expectedRevision: UInt64? = nil) async throws(ProfileStoreError) {
        await acquire(); defer { release() }
        guard let folder = document.folders.first(where: { $0.id == id }) else { throw .notFound }
        if let expectedRevision, folder.revision != expectedRevision { throw .conflict(expected: expectedRevision, actual: folder.revision) }
        var next = try nextDocument()
        next.folders.removeAll { $0.id == id }
        for index in next.profiles.indices where next.profiles[index].folderID == id {
            next.profiles[index].folderID = nil; next.profiles[index].revision = next.revision
        }
        try await commit(next, undo: Undo())
    }

    // MARK: Labels

    public func renameLabel(_ color: LabelColor, to name: String) async throws(ProfileStoreError) {
        guard ConnectionsDocument.isLabelName(name) else { throw .invalid(.label) }
        try await updateLabel(color) { $0.name = name }
    }

    /// Marks a label "treat as production" (FR-SF02). The built-in Production label can't be unmarked.
    public func setTreatAsProduction(_ color: LabelColor, _ value: Bool) async throws(ProfileStoreError) {
        guard color != .production || value else { throw .invalid(.label) }
        try await updateLabel(color) { $0.treatAsProduction = value }
    }

    // MARK: Import (FR-CN14)

    /// Applies an export in one commit, so a failure anywhere leaves every profile, folder and Keychain item as it
    /// was. Records are matched by ID (a profile also by the ID it was imported under); `policy` decides what a match
    /// does. An added profile always gets a new ID: the file's ID may be a profile of another Keel copy (installed,
    /// development, another state folder), and the Keychain items keyed by it are shared by all of them. New folders go after the saved ones and
    /// new profiles at the end of their folder, in file order. An import that changes nothing writes nothing.
    public func importProfiles(_ export: ProfileExport, policy: ProfileImportPolicy) async throws(ProfileStoreError) -> ProfileImportResult {
        await acquire(); defer { release() }
        // `ProfileExport` is public, so a caller-built one gets the same checks as a decoded file.
        do { _ = try export.validated() } catch { throw .invalidImport(error) }
        var next = try nextDocument()
        var result = ProfileImportResult()
        var undo = Undo()
        func place(_ profile: ConnectionProfile) { next.profiles.insert(profile, at: Self.insertionIndex(in: next.profiles, folderID: profile.folderID, position: nil)) }
        for folder in export.folders {
            guard let index = next.folders.firstIndex(where: { $0.id == folder.id }) else {
                next.folders.append(ProfileFolder(id: folder.id, name: folder.name, revision: next.revision)); result.foldersAdded += 1; continue
            }
            // Skip and Keep both share the saved folder as it is: only profiles are ever duplicated.
            if policy == .replace, next.folders[index].name != folder.name { next.folders[index].name = folder.name; next.folders[index].revision = next.revision; result.foldersRenamed += 1 }
        }
        for imported in export.profiles {
            guard let index = ProfileExport.match(imported.id, in: next.profiles) else {
                place(ConnectionProfile(id: makeID(), settings: imported.settings, folderID: imported.folderID, revision: next.revision, importedFrom: imported.id))
                result.added += 1; continue
            }
            switch policy {
            case .skip: result.skipped += 1
            case .keepBoth:
                var settings = imported.settings
                settings.name = Self.importedName(settings.name)
                place(ConnectionProfile(id: makeID(), settings: settings, folderID: imported.folderID, revision: next.revision)); result.added += 1
            case .replace:
                let current = next.profiles[index]
                guard current.settings != imported.settings || current.folderID != imported.folderID else { result.skipped += 1; continue }
                var profile = current
                profile.settings = imported.settings; profile.revision = next.revision
                // The same binding as `update`: a different server never gets the saved password. The TLS identity
                // stays, as it does for an edit.
                if imported.settings.connectionKey != current.settings.connectionKey || imported.settings.weakensTransport(from: current.settings) {
                    profile.connectionRevision = next.revision
                    if current.hasPassword { try stage(.password, nil, profileID: current.id, existed: true, undo: &undo); profile.hasPassword = false }
                    profile.savedHostBinding = nil
                }
                if profile.folderID == imported.folderID {
                    next.profiles[index] = profile
                } else {
                    profile.folderID = imported.folderID
                    next.profiles.remove(at: index); place(profile)
                }
                result.replaced += 1
            }
        }
        // Skip-only re-imports land here: no revision bump, no write, no change notification.
        guard next.folders != document.folders || next.profiles != document.profiles else { return result }
        try await commit(next, undo: undo)
        return result
    }

    /// "<name> (imported)", trimmed to the name limit so a long name still validates.
    static func importedName(_ name: String) -> String {
        let suffix = " (imported)"
        return String(name.prefix(ConnectionSettings.nameLimit - suffix.count)) + suffix
    }

    // MARK: Internals

    /// Keychain changes made ahead of a commit, undone in reverse if the commit (or a later step) fails.
    private struct Undo {
        var steps: [() -> Void] = []
        func run() { steps.reversed().forEach { $0() } }
    }

    /// Writes `value` (nil removes the item) before the metadata commit and records how to put the previous item
    /// back. `existed` false skips reading the previous value: there is nothing to restore but a removal.
    private func stage(_ secret: ProfileSecret, _ value: Data?, profileID: UUID, existed: Bool, undo: inout Undo) throws(ProfileStoreError) {
        let secrets = secrets
        do {
            let previous = existed ? try secrets.read(secret, profileID: profileID) : nil
            if let value { try secrets.write(value, secret, profileID: profileID) } else if previous != nil { try secrets.remove(secret, profileID: profileID) }
            undo.steps.append {
                if let previous { try? secrets.write(previous, secret, profileID: profileID) } else if value != nil { try? secrets.remove(secret, profileID: profileID) }
            }
        } catch {
            undo.run(); throw .secretStore(error)
        }
    }

    /// The binding a password saved now gets: the saved host as `HostLibrary` holds it, nil without a saved-host
    /// tunnel. A host that is gone can't take a password (`.invalid(.tunnel)`).
    private func savedHostBinding(_ settings: ConnectionSettings) async throws(ProfileStoreError) -> SavedHostBinding? {
        guard case .savedHost(let id) = settings.tunnel else { return nil }
        guard let host = await resolveSavedHost(id) else { throw .invalid(.tunnel) }
        return SavedHostBinding(host)
    }

    /// The profile's `Keel TLS` item, decoded; nil without one or in a format this Keel doesn't know.
    private func identitySecret(_ profile: ConnectionProfile) throws(ProfileStoreError) -> TLSIdentitySecret? {
        guard profile.hasTLSSecret else { return nil }
        let data: Data?
        do { data = try secrets.read(.tls, profileID: profile.id) } catch { throw .secretStore(error) }
        return data.flatMap { try? JSONDecoder().decode(TLSIdentitySecret.self, from: $0) }
    }

    /// Writes (or removes) the `Keel TLS` item for `change` and sets the flag on `profile`. Returns the identity the
    /// change lets go, for `release` once the metadata is saved. Re-importing the identity the profile already has
    /// keeps Keel's ownership of it.
    private func stageIdentity(_ change: TLSIdentityChange, on profile: inout ConnectionProfile, previous: TLSIdentitySecret?, undo: inout Undo) throws(ProfileStoreError)
        -> TLSIdentitySecret?
    {
        switch change {
        case .keep: return nil
        case .remove:
            try stage(.tls, nil, profileID: profile.id, existed: profile.hasTLSSecret, undo: &undo)
            profile.hasTLSSecret = false
            return previous
        case .set(let identity):
            let same = previous?.identity == identity.reference
            let secret = TLSIdentitySecret(identity: identity.reference, passphrase: identity.passphrase, addedByKeel: identity.isNew || (same && previous?.addedByKeel == true))
            let data: Data
            do { data = try JSONEncoder().encode(secret) } catch { undo.run(); throw .secretStore(.keychain(-50)) }
            try stage(.tls, data, profileID: profile.id, existed: profile.hasTLSSecret, undo: &undo)
            profile.hasTLSSecret = true
            return same ? nil : previous
        }
    }

    /// Removes an identity Keel's import added once no saved profile's `Keel TLS` item refers to it (duplicates share
    /// one). Runs after the commit and is best effort: a private key can't be put back, so it only goes once the
    /// metadata no longer needs it, and an item that can't be read counts as still using it.
    private func release(_ previous: TLSIdentitySecret?) {
        guard let previous, previous.addedByKeel == true else { return }
        for other in document.profiles where other.hasTLSSecret {
            let data: Data?
            do { data = try secrets.read(.tls, profileID: other.id) } catch { return }
            guard let data else { continue }
            // An item in a format this Keel doesn't know might still refer to it.
            guard let secret = try? JSONDecoder().decode(TLSIdentitySecret.self, from: data), secret.identity != previous.identity else { return }
        }
        removeTLSIdentity(previous.identity)
    }

    /// Records `binding` for the profile's password, or (nil) removes the password, Keychain first. Best effort and
    /// called with the lock held: the lookup it serves fails closed either way. The record revision stays, since no
    /// editor-visible field changes and an open editor (or its own Test Connection) must not get `CONFLICT`.
    private func rebind(_ id: UUID, _ binding: SavedHostBinding?) async {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }), var next = try? nextDocument() else { return }
        var undo = Undo()
        if binding == nil {
            do throws(ProfileStoreError) { try stage(.password, nil, profileID: id, existed: true, undo: &undo) } catch { return }
            next.profiles[index].hasPassword = false
        }
        next.profiles[index].savedHostBinding = binding
        try? await commit(next, undo: undo)
    }

    /// Publishes `next`; on failure the staged Keychain changes are undone and the in-memory document is unchanged.
    private func commit(_ next: ConnectionsDocument, undo: Undo) async throws(ProfileStoreError) {
        let written: Bool
        do { written = try await persistence.save(next, sequence: next.revision) } catch {
            undo.run(); throw Self.storeError(error)
        }
        // Unreachable while mutations are serialized; never treat an unwritten document as saved.
        guard written else { undo.run(); throw .persistence(.readOnly) }
        document = next
    }

    /// A copy of the document stamped with the next revision.
    private func nextDocument() throws(ProfileStoreError) -> ConnectionsDocument {
        guard isWritable else { throw .readOnly }
        var next = document
        next.revision += 1
        return next
    }

    private func locate(_ id: UUID, expectedRevision: UInt64) throws(ProfileStoreError) -> (Int, ConnectionProfile) {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let current = document.profiles[index]
        guard current.revision == expectedRevision else { throw .conflict(expected: expectedRevision, actual: current.revision) }
        return (index, current)
    }

    private func requireFolder(_ folderID: UUID?) throws(ProfileStoreError) {
        if let folderID, !document.folders.contains(where: { $0.id == folderID }) { throw .invalid(.folder) }
    }

    private func updateFolder(_ id: UUID, expectedRevision: UInt64?, _ change: (inout ProfileFolder) -> Void) async throws(ProfileStoreError) -> ProfileFolder {
        await acquire(); defer { release() }
        guard let index = document.folders.firstIndex(where: { $0.id == id }) else { throw .notFound }
        let current = document.folders[index]
        if let expectedRevision, current.revision != expectedRevision { throw .conflict(expected: expectedRevision, actual: current.revision) }
        var folder = current
        change(&folder)
        guard folder != current else { return current }
        var next = try nextDocument()
        folder.revision = next.revision
        next.folders[index] = folder
        try await commit(next, undo: Undo())
        return folder
    }

    private func updateLabel(_ color: LabelColor, _ change: (inout ProfileLabel) -> Void) async throws(ProfileStoreError) {
        await acquire(); defer { release() }
        guard let index = document.labels.firstIndex(where: { $0.color == color }) else { throw .notFound }
        var label = document.labels[index]
        change(&label)
        guard label != document.labels[index] else { return }
        var next = try nextDocument()
        next.labels[index] = label
        try await commit(next, undo: Undo())
    }

    private static func storeError(_ error: PersistenceError) -> ProfileStoreError { error == .readOnly ? .readOnly : .persistence(error) }

    private static func validate(_ password: Data) throws(ProfileStoreError) {
        guard !password.isEmpty, password.count <= passwordByteLimit else { throw .invalid(.password) }
    }

    /// The array index for `position` among the profiles of `folderID`; the end of the array when that group is
    /// empty or `position` is past its end, keeping display order within every group.
    static func insertionIndex(in profiles: [ConnectionProfile], folderID: UUID?, position: Int?) -> Int {
        let group = profiles.indices.filter { profiles[$0].folderID == folderID }
        guard let last = group.last else { return profiles.endIndex }
        guard let position, position < group.count else { return last + 1 }
        return group[max(position, 0)]
    }

    /// Serializes mutations: `Persistence` is another actor, so without this two edits could interleave across the
    /// save and the second would publish a document missing the first.
    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

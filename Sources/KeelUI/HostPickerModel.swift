import Foundation
import KeelSSH

/// The SSH host picker of the tunnel section (FR-CN06, INT-06): Keel's saved hosts (`hosts.json`) followed by the
/// literal aliases of `~/.ssh/config` that aren't saved yet. Discovery only parses the file; nothing in it is run.
/// Choosing an alias saves it as a host whose destination is the alias, so `/usr/bin/ssh` applies the user's config.
@MainActor
public final class HostPickerModel: ObservableObject {
    public typealias Discover = @Sendable () -> Result<SSHConfigDiscovery.Result, SSHConfigDiscovery.Failure>

    public enum Entry: Identifiable, Equatable, Sendable {
        case saved(SavedHost)
        case discovered(alias: String)

        public var id: String {
            switch self {
            case .saved(let host): "saved:\(host.id.uuidString)"
            case .discovered(let alias): "ssh-config:\(alias)"
            }
        }

        public var name: String {
            switch self {
            case .saved(let host): host.name
            case .discovered(let alias): alias
            }
        }
    }

    public let library: HostLibrary
    @Published public private(set) var saved: [SavedHost] = []
    /// Aliases from `~/.ssh/config` not already saved as a destination, in file order.
    @Published public private(set) var discovered: [String] = []
    /// What discovery couldn't list, labeled for the person: unfollowed `Include`s, an unreadable file.
    @Published public private(set) var notes: [String] = []
    /// The last failed import, in words; cleared by the next reload.
    @Published public private(set) var error: String?

    private let discover: Discover

    public init(library: HostLibrary, discover: @escaping Discover = HostPickerModel.discoverUserConfig) {
        self.library = library; self.discover = discover
    }

    public var entries: [Entry] { saved.map(Entry.saved) + discovered.map { .discovered(alias: $0) } }

    public func host(_ id: UUID?) -> SavedHost? { saved.first { $0.id == id } }

    /// Re-reads both sources. The config is read off the main actor (bounded to 1 MiB, never written).
    public func reload() async {
        let discover = discover
        let found = await Task.detached(priority: .userInitiated) { discover() }.value
        let hosts = await library.hosts
        saved = hosts; error = nil
        let destinations = Set(hosts.map(\.destination))
        switch found {
        case .success(let result):
            discovered = result.aliases.map(\.name).filter { !destinations.contains($0) }
            // Only Includes are labeled: patterns and Match blocks are never hosts, so listing them is noise.
            notes = result.warnings.compactMap { if case .include = $0 { $0.description } else { nil } }
        case .failure(.missing):
            discovered = []; notes = []
        case .failure(.unreadable(let reason)):
            discovered = []; notes = ["~/.ssh/config couldn't be read: \(reason)"]
        }
    }

    /// The saved host for `entry`. A discovered alias is saved first; nil (with `error` set) if that fails.
    public func choose(_ entry: Entry) async -> SavedHost? {
        switch entry {
        case .saved(let host): return host
        case .discovered(let alias):
            do throws(HostLibraryError) {
                let imported = try await library.importAliases([alias])
                await reload()
                // An empty import means the alias was saved meanwhile (a stale list): use that host.
                return imported.first ?? saved.first { $0.destination == alias }
            } catch {
                self.error = error.message; return nil
            }
        }
    }

    /// `~/.ssh/config` of the user running Keel.
    public nonisolated static func discoverUserConfig() -> Result<SSHConfigDiscovery.Result, SSHConfigDiscovery.Failure> {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        return SSHConfigDiscovery.discover(url, read: SSHConfigDiscovery.readConfig)
    }
}

/// Add / Edit SSH Host. The password is write-only (AC2): a saved one is never read back into the field; typing a new
/// one replaces it, and the field is wiped on Save and Cancel. It goes to the Keychain (`Keel SSH Host`) only on Save.
@MainActor
public final class HostEditorModel: ObservableObject, Identifiable {
    public enum Mode: Equatable, Sendable {
        case create
        case edit(SavedHost)
    }

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
    public let mode: Mode

    @Published public var name = ""
    @Published public var destination = ""
    @Published public var user = ""
    @Published public var port = ""
    @Published public var identityFile = ""
    /// Never filled from the Keychain; cleared on Save and Cancel.
    @Published public var password = ""
    /// Touch ID or the Mac password before each use of the saved password (INT-08).
    @Published public var requiresUserPresence = false
    /// Edit only: Save removes the saved password.
    @Published public var removePassword = false

    @Published public private(set) var fieldErrors: [HostField: String] = [:]
    @Published public private(set) var saveError: String?
    @Published public private(set) var isSaving = false
    /// Set once: the saved host, or nil after Cancel.
    @Published public private(set) var finished: SavedHost??

    private let library: HostLibrary
    /// The host as last committed: a later step of a partly failed Save starts from its revision, not a stale one.
    private var current: SavedHost?

    public init(mode: Mode, library: HostLibrary) {
        self.mode = mode; self.library = library
        if case .edit(let host) = mode {
            current = host
            name = host.name; destination = host.destination; user = host.user ?? ""; port = host.port.map(String.init) ?? ""
            identityFile = host.identityFile ?? ""; requiresUserPresence = host.savedPassword?.requiresUserPresence ?? false
        }
    }

    public var title: String { current == nil ? "Add SSH Host" : "Edit SSH Host" }
    public var hasSavedPassword: Bool { current?.savedPassword != nil }

    /// Edit only: the fields as typed would connect elsewhere (destination, user, port or identity file). Saving then
    /// drops the host's SSH password, and the connections that use the host lose their saved Redis password (FR-CN21).
    public var connectionChanged: Bool {
        guard let current else { return false }
        func optional(_ text: String) -> String? { let value = text.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
        return optional(destination) != current.destination || optional(user) != current.user || optional(port).flatMap { Int($0) } != current.port
            || optional(identityFile) != current.identityFile
    }

    /// Saves the metadata, then the password change. Each step commits on its own; a failure keeps the sheet open with
    /// what is already saved, so Save can be pressed again. A new host whose password the Keychain refused is removed.
    @discardableResult public func save() async -> SavedHost? {
        guard !isSaving, finished == nil else { return nil }
        fieldErrors = [:]; saveError = nil
        var secret: Data?
        if !password.isEmpty {
            do throws(HostValidationError) { secret = try HostPassword.validated(password) } catch {
                fieldErrors = error.fields; return nil
            }
        }
        // A blank name takes the destination, as a blank connection name takes the host.
        let draft = HostDraft(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? destination : name, destination: destination, user: user, port: port, identityFile: identityFile)
        isSaving = true
        defer { isSaving = false }
        do throws(HostLibraryError) {
            var host: SavedHost
            if let existing = current {
                host = try await library.update(id: existing.id, draft, expectedRevision: existing.revision)
                current = host
            } else {
                host = try await library.create(draft)
                if let secret {
                    do throws(HostLibraryError) {
                        host = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: requiresUserPresence), expectedRevision: host.revision)
                    } catch {
                        // All or nothing for a new host: without its password it isn't what the person asked to save.
                        // If even the removal fails, the host stays: the next Save edits it instead of adding a duplicate.
                        do throws(HostLibraryError) { try await library.delete(id: host.id, expectedRevision: host.revision) } catch { current = host }
                        throw error
                    }
                    finish(host); return host
                }
                current = host
            }
            if let secret {
                host = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: requiresUserPresence), expectedRevision: host.revision)
            } else if removePassword {
                host = try await library.setPassword(id: host.id, .remove, expectedRevision: host.revision)
            } else if let policy = host.savedPassword, policy.requiresUserPresence != requiresUserPresence {
                // A changed destination already dropped the password above, so a policy change is skipped then.
                host = try await library.setPassword(id: host.id, .policy(requiresUserPresence: requiresUserPresence), expectedRevision: host.revision)
            }
            finish(host)
            return host
        } catch .invalid(let validation) {
            fieldErrors = validation.fields; return nil
        } catch {
            saveError = error.message; return nil
        }
    }

    public func cancel() { finish(nil) }

    private func finish(_ host: SavedHost?) {
        password = ""
        finished = .some(host)
    }
}

extension HostLibraryError {
    /// One line for the host picker or editor.
    public var message: String {
        switch self {
        case .invalid(let error): error.fields.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value ?? "Check the host's fields."
        case .notFound: "This SSH host was deleted elsewhere."
        case .conflict: "This SSH host changed elsewhere; open it again."
        case .readOnly: "SSH hosts can't be saved: hosts.json is unreadable or was written by a newer Keel. Nothing was changed."
        case .io: "Couldn't save hosts.json; nothing was changed."
        case .secretStore: "The Keychain refused the password; nothing was changed."
        case .notAuthorized: "Touch ID or the Mac password was declined; nothing was changed."
        }
    }
}

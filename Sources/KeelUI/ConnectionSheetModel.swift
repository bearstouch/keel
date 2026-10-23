import Combine
import Foundation
import KeelCore
import KeelSSH

/// Where the New Connection sheet saves: `ProfileStore` in the app, a fake in tests.
public protocol ProfileSaving: Sendable {
    func create(_ settings: ConnectionSettings, folderID: UUID?, password: Data?) async throws(ProfileStoreError) -> ConnectionProfile
    func update(_ id: UUID, _ settings: ConnectionSettings, password: PasswordChange, expectedRevision: UInt64) async throws(ProfileStoreError) -> ConnectionProfile
    func password(profileID: UUID, connectionRevision: UInt64) async throws(ProfileStoreError) -> Data?
}

extension ProfileStore: ProfileSaving {}

/// The New / Edit Connection sheet's state (FR-CN19, FR-CN08, FR-CN10). Fields are plain text until Save or Test turns
/// them into `ConnectionSettings`, so a half-typed port never corrupts anything. Only `save()` writes: the password
/// reaches the Keychain through `ProfileStore` then, and Cancel or Test leave nothing behind (AC3).
@MainActor
public final class ConnectionSheetModel: ObservableObject {
    public enum Mode: Equatable {
        case create(folderID: UUID?)
        case edit(ConnectionProfile)
    }

    /// The collapsed rows; closing one keeps its values (they still apply on Save).
    public enum Section: String, CaseIterable, Sendable {
        case tls = "TLS", tunnel = "SSH tunnel", advanced = "Advanced"
    }

    public enum TunnelKind: String, CaseIterable, Sendable {
        case none = "None", savedHost = "Saved host", inline = "Custom"
    }

    public enum TestStatus: Equatable {
        case idle, testing
        case succeeded(String)
        case failed(ConnectionFailure)
        /// A field blocks the test; nothing was sent.
        case invalid(String)
    }

    public enum Outcome: Equatable {
        case saved(ConnectionProfile)
        case cancelled
    }

    public let mode: Mode
    public let labels: [ProfileLabel]
    /// The SSH host picker; nil without a host library (tests, previews), which hides the saved-host option.
    public let hosts: HostPickerModel?
    public var sshHosts: [SavedHost] { hosts?.saved ?? [] }

    // MARK: Fields, in sheet order

    @Published public var urlText = ""
    @Published public var name = ""
    @Published public var host = "127.0.0.1"
    @Published public var port = "6379"
    @Published public var username = ""
    /// Never persisted or logged; cleared on Cancel and after Save.
    @Published public var password = ""
    @Published public var label: LabelColor = .none
    @Published public var readOnly = false

    @Published public var tlsEnabled = false
    @Published public var tlsServerName = ""
    @Published public var tlsCAFile = ""
    @Published public var tlsSkipVerification = false

    @Published public var tunnelKind: TunnelKind = .none
    @Published public var tunnelHostID: UUID?
    @Published public var tunnelDestination = ""
    @Published public var tunnelUser = ""
    @Published public var tunnelPort = ""
    @Published public var tunnelIdentityFile = ""

    @Published public var database = "0"
    @Published public var connectTimeout = ""
    @Published public var commandTimeout = ""
    @Published public var separator = ""
    @Published public var clientName = ""
    @Published public var reconnectOnLaunch = false
    /// Edit only: Save removes the saved password.
    @Published public var removeSavedPassword = false

    @Published public var expanded: Set<Section> = []

    // MARK: Feedback

    /// The URL paste result: what was ignored, or why the URL was refused (FR-CN08).
    @Published public private(set) var urlMessage: String?
    @Published public private(set) var testStatus: TestStatus = .idle
    @Published public private(set) var saveError: String?
    @Published public private(set) var isSaving = false
    @Published public private(set) var outcome: Outcome?

    private let tester: any ConnectionTesting
    private let store: any ProfileSaving
    private var testTask: Task<Void, Never>?
    /// The URL field's previous text, to tell a paste from typing.
    private var lastURLText = ""
    /// What the last finished test ran with, so its line disappears as soon as a field changes.
    private var testedDraft: Draft?
    private var hostChanges: AnyCancellable?
    /// Bumped by every host choice, so an alias import that finishes late never overrides a later choice.
    private(set) var hostChoice = 0

    public init(mode: Mode, labels: [ProfileLabel] = ProfileLabel.defaults, hosts: HostPickerModel? = nil, tester: any ConnectionTesting, store: any ProfileSaving) {
        self.mode = mode; self.labels = labels; self.hosts = hosts; self.tester = tester; self.store = store
        if case .edit(let profile) = mode { load(profile.settings) }
        // The collapsed tunnel row names the chosen host, so the sheet redraws when the host list changes.
        hostChanges = hosts?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Picks `entry` as the tunnel's SSH host; a `~/.ssh/config` alias is saved to the host library first.
    /// nil clears the choice ("Choose…").
    public func useHost(_ entry: HostPickerModel.Entry?) async {
        hostChoice += 1
        let choice = hostChoice
        guard let entry else { tunnelHostID = nil; return }
        guard let host = await hosts?.choose(entry), choice == hostChoice else { return }
        tunnelKind = .savedHost; tunnelHostID = host.id
    }

    public var title: String { isEditing ? "Edit Connection" : "New Connection" }
    public var isEditing: Bool { if case .edit = mode { true } else { false } }
    public var hasSavedPassword: Bool { if case .edit(let profile) = mode { profile.hasPassword } else { false } }

    // MARK: URL paste

    /// Fills the fields from a pasted `redis://` / `rediss://` URL. The URL field is cleared afterwards: it may hold the
    /// password in plain text, and the URL itself is never saved. A refused URL changes no field.
    @discardableResult public func applyURL(_ text: String) -> Bool {
        let parsed: RedisURL
        do throws(RedisURLError) { parsed = try RedisURL(parsing: text) } catch {
            urlMessage = error.message; return false
        }
        var secret: String?
        if let bytes = parsed.password {
            // HELLO/AUTH send text; a password that isn't UTF-8 can't be typed or sent as given.
            guard let text = String(data: bytes, encoding: .utf8) else { urlMessage = "The password in the URL isn't valid text; type it in the Password field."; return false }
            secret = text
        }
        host = parsed.host; port = String(parsed.port); username = parsed.username ?? ""; database = String(parsed.database)
        if let secret { password = secret; removeSavedPassword = false }
        tlsEnabled = parsed.tls
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = String(parsed.host.prefix(ConnectionSettings.nameLimit)) }
        urlText = ""; lastURLText = ""
        urlMessage = parsed.ignoredQueryParameters.isEmpty ? nil : "Ignored: \(parsed.ignoredQueryParameters.joined(separator: ", "))"
        return true
    }

    /// The URL field changed: a pasted URL is applied at once, so pasting is enough. Typing (one character added or
    /// removed) waits for Return, or "redis://c" would fill Host and Name and clear the field mid-word.
    public func urlTextChanged() {
        let previous = lastURLText; lastURLText = urlText
        guard !urlText.isEmpty else { return }
        let typed = abs(urlText.count - previous.count) <= 1 && (urlText.hasPrefix(previous) || previous.hasPrefix(urlText))
        if !typed, RedisURL.isCandidate(urlText) { applyURL(urlText) } else { urlMessage = nil }
    }

    /// ⌘V on the sheet outside a text field (FR-CN08). Returns false for text that isn't a connection URL.
    @discardableResult public func paste(_ text: String) -> Bool {
        guard RedisURL.isCandidate(text) else { return false }
        return applyURL(text)
    }

    // MARK: Validation

    /// The settings the fields describe, validated as the store will validate them.
    public func settings() throws(ProfileStoreError) -> ConnectionSettings {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let hostText = host.trimmingCharacters(in: .whitespaces)
        // Checked first: a blank name falls back to the host, so a blank host would otherwise read as a bad name.
        guard !hostText.isEmpty else { throw .invalid(.host) }
        guard let portValue = Self.number(port).flatMap(UInt16.init(exactly:)), portValue > 0 else { throw .invalid(.port) }
        guard let databaseValue = Self.number(database) else { throw .invalid(.database) }
        var settings = ConnectionSettings(
            // A blank name takes the host, so a plain local profile needs nothing but Save.
            name: trimmedName.isEmpty ? String(hostText.prefix(ConnectionSettings.nameLimit)) : name, label: label, host: hostText, port: portValue,
            username: Self.optional(username), database: databaseValue, readOnly: readOnly, separator: separator.isEmpty ? nil : separator,
            clientName: Self.optional(clientName), reconnectOnLaunch: reconnectOnLaunch)
        if tlsEnabled { settings.tls = TLSSettings(serverName: Self.optional(tlsServerName), caFile: Self.optional(tlsCAFile), skipVerification: tlsSkipVerification) }
        switch tunnelKind {
        case .none: break
        case .savedHost:
            guard let tunnelHostID else { throw .invalid(.tunnel) }
            settings.tunnel = .savedHost(id: tunnelHostID)
        case .inline:
            guard let destination = Self.optional(tunnelDestination) else { throw .invalid(.tunnel) }
            var sshPort: Int?
            if !tunnelPort.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let value = Self.number(tunnelPort), (1...65_535).contains(value) else { throw .invalid(.tunnel) }
                sshPort = value
            }
            settings.tunnel = .inline(destination: destination, user: Self.optional(tunnelUser), port: sshPort, identityFile: Self.optional(tunnelIdentityFile))
        }
        for (text, field, keyPath) in [
            (connectTimeout, ProfileField.connectTimeout, \ConnectionSettings.connectTimeoutMilliseconds), (commandTimeout, .commandTimeout, \.commandTimeoutMilliseconds)
        ] where !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = Self.number(text) else { throw .invalid(field) }
            settings[keyPath: keyPath] = value
        }
        if password.utf8.count > ProfileStore.passwordByteLimit { throw .invalid(.password) }
        return try settings.validated()
    }

    /// The first field Save would refuse; nil when the sheet can be saved.
    public var invalidField: ProfileField? {
        do throws(ProfileStoreError) { _ = try settings(); return nil } catch .invalid(let field) { return field } catch { return nil }
    }

    public var canSave: Bool { invalidField == nil && !isSaving && outcome == nil }

    /// Why `field` blocks Save, in words for the inline message.
    public nonisolated static func message(for field: ProfileField) -> String {
        switch field {
        case .name: "Enter a name without control characters."
        case .host: "Enter a host name or IP address."
        case .port: "The port must be a number from 1 to 65535."
        case .username: "The username can't contain spaces or control characters."
        case .password: "The password is longer than 4096 bytes."
        case .database: "The database must be a number from 0 to 65535."
        case .serverName: "Enter a valid TLS server name."
        case .caFile: "Choose the CA file again; it needs a full path."
        case .tunnel: "Complete the SSH tunnel: choose a host, or enter a valid destination and port."
        case .connectTimeout: "The connect timeout must be 100–600000 ms."
        case .commandTimeout: "The command timeout must be 100–600000 ms."
        case .separator: "The separator must be 1–4 bytes, without control characters."
        case .clientName: "The client name can't contain spaces or control characters."
        case .folder: "The folder no longer exists."
        case .label: "Choose a label."
        }
    }

    /// The section a field lives in, so a collapsed row with a problem can say so.
    public nonisolated static func section(of field: ProfileField) -> Section? {
        switch field {
        case .serverName, .caFile: .tls
        case .tunnel: .tunnel
        case .database, .connectTimeout, .commandTimeout, .separator, .clientName: .advanced
        default: nil
        }
    }

    /// Edit only: Save will drop the saved password because the connection now reaches a different server.
    public var savedPasswordWillBeRemoved: Bool {
        guard case .edit(let profile) = mode, profile.hasPassword, password.isEmpty, !removeSavedPassword, let settings = try? settings() else { return false }
        return Self.connectionChanged(settings, from: profile.settings)
    }

    // MARK: Test

    /// The status line, hidden once the fields differ from what was tested.
    public var visibleTestStatus: TestStatus {
        switch testStatus {
        case .idle, .testing: return testStatus
        case .succeeded, .failed, .invalid: return testedDraft == currentDraft ? testStatus : .idle
        }
    }

    /// Runs the full handshake with the current fields without saving anything (FR-CN10). For an edited profile with
    /// an empty password field, the saved password is used only while the connection still reaches the same server.
    public func test() {
        guard testStatus != .testing else { return }
        let settings: ConnectionSettings
        do throws(ProfileStoreError) { settings = try self.settings() } catch {
            testStatus = .invalid(error.sheetMessage); testedDraft = currentDraft; return
        }
        testStatus = .testing
        let draft = currentDraft
        let typed = typedPassword
        let profile: ConnectionProfile? = if case .edit(let profile) = mode { profile } else { nil }
        var useSaved = false
        if typed == nil, !removeSavedPassword, let profile { useSaved = profile.hasPassword && !Self.connectionChanged(settings, from: profile.settings) }
        testTask = Task { [tester, store] in
            var secret = typed
            if useSaved, let profile { secret = try? await store.password(profileID: profile.id, connectionRevision: profile.connectionRevision) }
            let result = await tester.test(settings, password: secret, profileID: profile?.id)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let found): self.testStatus = .succeeded(found.summary)
            case .failure(let failure): self.testStatus = .failed(failure)
            }
            self.testedDraft = draft
        }
    }

    /// Awaits a running test; for tests and callers that need its result.
    public func waitForTest() async { await testTask?.value }

    // MARK: Save and Cancel

    /// Creates or updates the profile; the password goes to the Keychain only here, through the store.
    @discardableResult public func save() async -> ConnectionProfile? {
        guard !isSaving, outcome == nil else { return nil }
        let settings: ConnectionSettings
        do throws(ProfileStoreError) { settings = try self.settings() } catch {
            saveError = error.sheetMessage; return nil
        }
        isSaving = true; saveError = nil
        defer { isSaving = false }
        let typed = typedPassword
        do throws(ProfileStoreError) {
            let profile: ConnectionProfile
            switch mode {
            case .create(let folderID): profile = try await store.create(settings, folderID: folderID, password: typed)
            case .edit(let current):
                let change: PasswordChange = typed.map { .set($0) } ?? (removeSavedPassword ? .remove : .keep)
                profile = try await store.update(current.id, settings, password: change, expectedRevision: current.revision)
            }
            finish(.saved(profile))
            return profile
        } catch {
            saveError = error.sheetMessage; return nil
        }
    }

    /// Discards every change: a running test is cancelled and the typed or pasted password is wiped. Nothing was
    /// written, so nothing has to be undone.
    public func cancel() { finish(.cancelled) }

    private func finish(_ result: Outcome) {
        testTask?.cancel(); testTask = nil
        password = ""; urlText = ""; lastURLText = ""
        outcome = result
    }

    // MARK: Internals

    /// Everything a test depends on; the password only as a hash, never its value.
    private struct Draft: Equatable {
        var settings: ConnectionSettings?
        var password: Int
        var removeSavedPassword: Bool
    }

    private var typedPassword: Data? { password.isEmpty ? nil : Data(password.utf8) }

    private var currentDraft: Draft { Draft(settings: try? settings(), password: password.hashValue, removeSavedPassword: removeSavedPassword) }

    private func load(_ settings: ConnectionSettings) {
        name = settings.name; host = settings.host; port = String(settings.port); username = settings.username ?? ""; label = settings.label; readOnly = settings.readOnly
        if let tls = settings.tls {
            tlsEnabled = true; tlsServerName = tls.serverName ?? ""; tlsCAFile = tls.caFile ?? ""; tlsSkipVerification = tls.skipVerification
        }
        switch settings.tunnel {
        case .none: tunnelKind = .none
        case .savedHost(let id): tunnelKind = .savedHost; tunnelHostID = id
        case .inline(let destination, let user, let port, let identityFile):
            tunnelKind = .inline; tunnelDestination = destination; tunnelUser = user ?? ""; tunnelPort = port.map(String.init) ?? ""; tunnelIdentityFile = identityFile ?? ""
        }
        database = String(settings.database)
        connectTimeout = settings.connectTimeoutMilliseconds.map(String.init) ?? ""; commandTimeout = settings.commandTimeoutMilliseconds.map(String.init) ?? ""
        separator = settings.separator ?? ""; clientName = settings.clientName ?? ""; reconnectOnLaunch = settings.reconnectOnLaunch
    }

    /// Mirrors `ProfileStore.update`'s rule for removing the saved password.
    static func connectionChanged(_ settings: ConnectionSettings, from previous: ConnectionSettings) -> Bool {
        settings.connectionKey != previous.connectionKey || settings.weakensTransport(from: previous)
    }

    /// ASCII digits only (no sign, no "٦"), at most 9 so the value fits any field's range check.
    private static func number(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 9, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ProfileStoreError {
    /// One line for the sheet's footer.
    var sheetMessage: String {
        switch self {
        case .invalid(let field): ConnectionSheetModel.message(for: field)
        case .notFound: "This connection was deleted elsewhere."
        case .conflict: "This connection changed elsewhere; close the sheet and edit it again."
        case .readOnly: "Connections can't be saved right now: they are being recovered or were written by a newer Keel."
        case .persistence: "Couldn't save connections.json; nothing was changed."
        case .secretStore(.keychain(let status)): "The Keychain refused the password (\(status)); nothing was changed."
        }
    }
}

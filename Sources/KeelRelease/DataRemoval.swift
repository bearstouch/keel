import Darwin
import Foundation
import Security

/// The Keychain calls Help → Remove Keel Data… needs, injectable so tests never touch the user's Keychain.
public protocol KeychainInventory: Sendable {
    /// Every account stored under `service`; none is an empty list, not an error.
    func accounts(service: String) throws(DataRemovalError) -> [String]
    /// Removes one item; a missing item is not an error.
    func remove(service: String, account: String) throws(DataRemovalError)
}

public enum DataRemovalError: Error, Equatable, Sendable {
    /// A Keychain call failed with this OSStatus (locked, denied).
    case keychain(Int32)
}

/// What Remove Keel Data… removes (MAC-22), decided by allow-list: the state folder's own files, the generic passwords of
/// Keel's three Keychain services and Keel's preference keys. Nothing is matched by pattern outside the state folder, so
/// SSH keys, SSH configuration, known-hosts files and other apps' data can't be in a plan.
public struct DataRemovalPlan: Equatable, Sendable {
    public struct KeychainItem: Hashable, Sendable {
        public var service: String, account: String

        public init(service: String, account: String) { self.service = service; self.account = account }
    }

    /// What a plan may reach.
    public enum Scope: Equatable, Sendable {
        /// The state folder, Keel's Keychain items and its preference keys.
        case everything
        /// The state folder alone (`--fixture`): the run kept its secrets in memory, and the Keychain items and
        /// preferences it could see belong to the other copies of Keel on this Mac.
        case stateFolderOnly
    }

    public var stateDirectory: URL
    public var scope: Scope
    /// Names of Keel's files directly in the state folder, sorted.
    public var files: [String] = []
    /// Other entries found there: left in place, so the folder itself stays.
    public var keptEntries: [String] = []
    public var keychainItems: [KeychainItem] = []
    public var preferenceKeys: [String] = []
    /// Why the state folder isn't touched at all (a protected location or a symlink); nil when it is planned normally.
    public var refusal: String?
    /// Keychain services that couldn't be listed, with their status: their items stay.
    public var unreadableServices: [String] = []
    /// False when the folder is missing: there is nothing to remove there.
    public var directoryExists = false

    public init(stateDirectory: URL, scope: Scope = .everything) { self.stateDirectory = stateDirectory; self.scope = scope }

    /// The folder goes too only when nothing but Keel's files is in it; `rmdir` refuses anything else anyway.
    public var removesDirectory: Bool { directoryExists && refusal == nil && keptEntries.isEmpty }

    public var isEmpty: Bool { files.isEmpty && keychainItems.isEmpty && preferenceKeys.isEmpty && !removesDirectory }

    /// One line per item group, for the confirmation.
    public var summary: [String] {
        var lines: [String] = []
        if let refusal {
            lines.append(refusal)
        } else if directoryExists {
            lines.append(removesDirectory ? "The state folder \(stateDirectory.path) and its \(Self.count(files.count, "file"))" : "\(Self.count(files.count, "Keel file")) in \(stateDirectory.path)")
            if !keptEntries.isEmpty { lines.append("Kept there (not Keel's): \(keptEntries.joined(separator: ", "))") }
        }
        for service in DataRemovalPlanner.keychainServices {
            let count = keychainItems.filter { $0.service == service }.count
            if count > 0 { lines.append("\(Self.count(count, "Keychain item")) in “\(service)”") }
        }
        lines += unreadableServices.map { "Couldn't read the Keychain items in \($0); they stay." }
        if !preferenceKeys.isEmpty { lines.append("Keyboard shortcut and update preferences") }
        return lines
    }

    private static func count(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

/// What a removal could not do, one line each; empty means everything planned is gone.
public struct DataRemovalResult: Equatable, Sendable {
    public var failures: [String] = []

    public init(failures: [String] = []) { self.failures = failures }
}

public enum DataRemovalPlanner {
    /// 02 Architecture → Keychain items. `DataRemovalPlannerTests` checks these against KeelCore and KeelSSH.
    public static let keychainServices = ["Keel Connection", "Keel TLS", "Keel SSH Host"]
    /// `UserDefaults` keys Keel writes: the keyboard bindings (FR-AP02) and what Sparkle remembers (FR-AP07).
    public static let preferenceKeys = ["keyboardShortcuts"] + UpdatePolicy.sparklePreferenceKeys
    /// The stems of Keel's state files (`PersistedFile`, `hosts.json`); checked against KeelCore by the tests.
    public static let stateFileStems = ["connections", "hosts", "windows", "settings", "known-ca"]
    /// The single-instance lock (`InstanceLock.fileName`, MAC-17); checked against KeelCore by the tests.
    public static let instanceLockFile = "instance.lock"

    /// Whether `name` is a file Keel writes in its state folder: `<stem>.json`, `<stem>.backup.json`, a recovery copy
    /// (`<stem>.corrupt.<UUID>.json`, `<stem>.unreadable.<UUID>.json`) or an atomic-write leftover (`.<stem>.<UUID>.tmp`).
    /// The instance lock and Finder's `.DS_Store` count too, so a folder the user once opened can still go.
    public static func isKeelFile(_ name: String) -> Bool {
        if name == ".DS_Store" || name == instanceLockFile { return true }
        for stem in stateFileStems {
            if name == "\(stem).json" || name == "\(stem).backup.json" { return true }
            for marker in ["corrupt", "unreadable"] where isUUID(name, between: "\(stem).\(marker).", and: ".json") { return true }
            if isUUID(name, between: ".\(stem).", and: ".tmp") { return true }
        }
        return false
    }

    private static func isUUID(_ name: String, between prefix: String, and suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }

    /// Why `directory` must never be emptied, or nil. Home, any folder above it and `~/.ssh` (or anything in it) are
    /// refused even when `--state-directory` named them, so a mistyped flag can't take files from there.
    public static func protectedReason(_ directory: URL, home: URL) -> String? {
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let ssh = homePath + [".ssh"]
        // A prefix of home's components is home itself or a folder above it ("/" included).
        if homePath.starts(with: path) { return "The state folder \(directory.path) is your home folder or above it, so nothing in it is removed." }
        if path.starts(with: ssh) { return "The state folder \(directory.path) is inside ~/.ssh, so nothing in it is removed." }
        return nil
    }

    /// Lists what a removal would take. Reads only: the folder's direct entries (never following links) and the
    /// accounts of Keel's Keychain services. `storedPreferenceKeys` are the keys the defaults hold now. A
    /// `.stateFolderOnly` plan never lists the Keychain and plans no preference key.
    public static func plan(
        stateDirectory: URL, home: URL, keychain: any KeychainInventory, storedPreferenceKeys: Set<String>, scope: DataRemovalPlan.Scope = .everything,
        fileManager: FileManager = .default
    ) -> DataRemovalPlan {
        var plan = DataRemovalPlan(stateDirectory: stateDirectory, scope: scope)
        var info = stat()
        if lstat(stateDirectory.path, &info) == 0 {
            plan.directoryExists = true
            switch info.st_mode & S_IFMT {
            case S_IFLNK: plan.refusal = "The state folder \(stateDirectory.path) is a symbolic link, so nothing in it is removed."
            case S_IFDIR: plan.refusal = protectedReason(stateDirectory, home: home)
            default: plan.refusal = "The state location \(stateDirectory.path) is not a folder, so it is left alone."
            }
            if plan.refusal == nil {
                let entries = ((try? fileManager.contentsOfDirectory(atPath: stateDirectory.path)) ?? []).sorted()
                for name in entries {
                    // Only regular files: a folder or link with a Keel name was put there by someone else.
                    var entry = stat()
                    let regular = lstat(stateDirectory.appendingPathComponent(name).path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFREG
                    if regular && isKeelFile(name) { plan.files.append(name) } else { plan.keptEntries.append(name) }
                }
            }
        }
        guard scope == .everything else { return plan }
        for service in keychainServices {
            do throws(DataRemovalError) {
                plan.keychainItems += try keychain.accounts(service: service).sorted().map { DataRemovalPlan.KeychainItem(service: service, account: $0) }
            } catch {
                if case .keychain(let status) = error { plan.unreadableServices.append("“\(service)” (\(status))") }
            }
        }
        plan.preferenceKeys = preferenceKeys.filter(storedPreferenceKeys.contains)
        return plan
    }

    /// Removes what `plan` lists and nothing else: each file by name (`unlink`, which never follows a link), the folder
    /// with `rmdir` (which fails rather than delete anything that appeared since), each Keychain item by service and
    /// account, and each preference key. A failure is reported and the rest still runs.
    public static func execute(_ plan: DataRemovalPlan, keychain: any KeychainInventory, removePreference: (String) -> Void) -> DataRemovalResult {
        var result = DataRemovalResult()
        if plan.refusal == nil {
            for name in plan.files where unlink(plan.stateDirectory.appendingPathComponent(name).path) != 0 && errno != ENOENT {
                result.failures.append("\(name): \(String(cString: strerror(errno)))")
            }
            if plan.removesDirectory, rmdir(plan.stateDirectory.path) != 0, errno != ENOENT {
                result.failures.append("The state folder \(plan.stateDirectory.path) stays: \(String(cString: strerror(errno)))")
            }
        }
        for item in plan.keychainItems where plan.scope == .everything {
            do throws(DataRemovalError) { try keychain.remove(service: item.service, account: item.account) } catch {
                if case .keychain(let status) = error { result.failures.append("Keychain item in “\(item.service)”: error \(status)") }
            }
        }
        plan.preferenceKeys.forEach(removePreference)
        return result
    }
}

/// Generic passwords in the login Keychain. Listing asks for attributes only, never the secrets, so it shows no prompt.
public struct SystemKeychainInventory: KeychainInventory {
    public init() {}

    public func accounts(service: String) throws(DataRemovalError) -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw .keychain(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func remove(service: String, account: String) throws(DataRemovalError) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }
}

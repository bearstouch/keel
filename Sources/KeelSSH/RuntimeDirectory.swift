import Darwin
import Foundation

public enum RuntimeDirectoryError: Error, Equatable, Sendable {
    /// The folder (or a file in it) exists but isn't an owner-only directory of this user: a symlink, another user's,
    /// or group/other accessible. Never used.
    case unsafe
    /// A socket path would not fit `sockaddr_un.sun_path` (104 bytes on macOS).
    case pathTooLong
    case io(Int32)
}

/// The owner-only folder for tunnel sockets (NFR-SC04): `<per-user $TMPDIR>/keel-run-<random>`, `0700`, never through a
/// symlink. It also holds the records stale-tunnel cleanup reads on the next launch: `owner` (the app's identity) and
/// `t-<id>.pid` (each ssh's identity). Names stay short so `<folder>/t-<id>.sock` fits `sun_path`.
public final class RuntimeDirectory: Sendable {
    public static let prefix = "keel-run-"
    static let ownerRecord = "owner"
    static let recordLimit = 4_096
    public let path: String

    private init(path: String) { self.path = path }

    /// Creates a fresh folder with a random name (or `name`, for tests) under `base` and records the owning app.
    /// An existing entry at that path, symlink or not, is refused rather than reused.
    public static func create(base: String = NSTemporaryDirectory(), name: String? = nil, owner: OwnedProcessIdentity? = OwnedProcessIdentity.read(getpid())) throws(RuntimeDirectoryError)
        -> RuntimeDirectory
    {
        let folder = (base as NSString).appendingPathComponent(name ?? prefix + randomID())
        guard mkdir(folder, 0o700) == 0 else { throw errno == EEXIST ? .unsafe : .io(errno) }
        // mkdir applies the umask; set the mode explicitly, then verify through lstat.
        guard chmod(folder, 0o700) == 0, isOwnerOnlyDirectory(folder) else { rmdir(folder); throw .unsafe }
        let directory = RuntimeDirectory(path: folder)
        if let owner {
            do { try directory.writeRecord(owner, named: ownerRecord) } catch { rmdir(folder); throw error }
        }
        return directory
    }

    /// 12 hex characters (48 random bits): unguessable, and short enough for `sun_path`.
    public static func randomID() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// `<folder>/t-<id>.sock`, refused when it would not fit a Unix socket address.
    public func socketPath(id: String) throws(RuntimeDirectoryError) -> String {
        let socket = path + "/" + socketName(id: id)
        guard socket.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw .pathTooLong }
        return socket
    }

    func recordName(id: String) -> String { "t-\(id).pid" }
    private func socketName(id: String) -> String { "t-\(id).sock" }

    /// Records a spawned ssh so a later launch can terminate it if this app dies without cleaning up.
    func writeRecord(_ identity: OwnedProcessIdentity, named name: String) throws(RuntimeDirectoryError) {
        guard let data = try? JSONEncoder().encode(identity) else { throw .io(EINVAL) }
        let fd = open(path + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io(errno) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw .io(errno) }
    }

    /// Removes one tunnel's socket and record. Only unlinks; never follows a symlink.
    func removeTunnelFiles(id: String) {
        unlink(path + "/" + socketName(id: id)); unlink(path + "/" + recordName(id: id))
    }

    /// Removes the folder and everything Keel put in it. Unknown entries are left, so `rmdir` then fails safely.
    public func remove() { Self.removeFolder(path) }

    static func removeFolder(_ folder: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name == ownerRecord || (name.hasPrefix("t-") && (name.hasSuffix(".sock") || name.hasSuffix(".pid"))) {
            unlink(folder + "/" + name)
        }
        rmdir(folder)
    }

    /// A real directory (not a symlink) owned by this user with no group or other access.
    public static func isOwnerOnlyDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }

    /// A Unix socket (not a symlink to one) owned by this user.
    public static func isOwnedSocket(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
    }

    static func readRecord(_ path: String) -> OwnedProcessIdentity? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= recordLimit else { return nil }
        var buffer = [UInt8](repeating: 0, count: recordLimit)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(OwnedProcessIdentity.self, from: Data(buffer.prefix(count)))
    }
}

/// Finds tunnels a previous Keel run left behind (it crashed or was killed) and terminates them (NFR-RS05).
/// A folder is stale only when its recorded owner is no longer the same live process; an ssh is signalled only when it
/// is still the process that was recorded (same pid and start time), still its own group leader, orphaned to launchd
/// and running `/usr/bin/ssh`. Folders of a running Keel (installed and development builds can run at once) are left alone.
public struct StaleTunnelCleanup: Sendable {
    public var base: String
    var readIdentity: @Sendable (Int32) -> OwnedProcessIdentity? = OwnedProcessIdentity.read
    var executablePath: @Sendable (Int32) -> String? = StaleTunnelCleanup.executablePath
    var signalGroup: @Sendable (Int32, Int32) -> Void = { _ = kill(-$0, $1) }
    /// A folder younger than this without an `owner` record may still be being created by another launch.
    var ownerlessGrace: TimeInterval = 30
    var now: @Sendable () -> Date = { Date() }

    public init(base: String = NSTemporaryDirectory()) { self.base = base }

    /// Returns the number of ssh process groups signalled.
    @discardableResult
    public func run() -> Int {
        var signalled = 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        for name in names where name.hasPrefix(RuntimeDirectory.prefix) {
            let folder = (base as NSString).appendingPathComponent(name)
            guard RuntimeDirectory.isOwnerOnlyDirectory(folder) else { continue }
            if let owner = RuntimeDirectory.readRecord(folder + "/" + RuntimeDirectory.ownerRecord) {
                if owner.isSameProcess(as: readIdentity(owner.pid)) { continue }
            } else if let modified = (try? FileManager.default.attributesOfItem(atPath: folder))?[.modificationDate] as? Date, now().timeIntervalSince(modified) < ownerlessGrace {
                continue
            }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for entry in entries where entry.hasPrefix("t-") && entry.hasSuffix(".pid") {
                guard let recorded = RuntimeDirectory.readRecord(folder + "/" + entry), let current = readIdentity(recorded.pid) else { continue }
                guard recorded.isSameProcess(as: current), current.groupID == recorded.pid, current.parentPID == 1, executablePath(recorded.pid) == SSHTunnelArguments.executable else { continue }
                signalGroup(recorded.pid, SIGTERM)
                signalled += 1
            }
            RuntimeDirectory.removeFolder(folder)
        }
        return signalled
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

import Darwin
import Foundation

/// One Keel per state folder (MAC-17): an exclusive `flock` on `instance.lock` inside the folder, taken before any
/// state is read and held for the life of the process. The kernel drops it when the process ends, crashes included,
/// so a stale file never blocks a launch. Each identity, `--state-directory` and `--fixture` folder has its own lock.
public final class InstanceLock {
    public static let fileName = "instance.lock"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Another process holds the lock; `owner` is the PID it recorded, when readable.
        case held(path: String, owner: pid_t?)
        case unusable(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .held(let path, let owner): return "Keel is already running with the state folder \(path)\(owner.map { " (process \($0))" } ?? "")."
            case .unusable(let path, let code): return "Instance lock \(path) can't be used: \(String(cString: strerror(code)))."
            }
        }
    }

    public let url: URL
    private var descriptor: Int32

    /// Takes the lock in `directory` (already prepared by `StateLocation.prepare`). A symlink, a non-regular file or a
    /// file owned by someone else at the lock path is refused rather than used.
    public init(directory: URL) throws(Failure) {
        url = directory.appendingPathComponent(Self.fileName)
        let path = url.path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw .unusable(path: path, errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { close(fd); throw .unusable(path: path, errno: EPERM) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            defer { close(fd) }
            guard code == EWOULDBLOCK else { throw .unusable(path: path, errno: code) }
            throw .held(path: directory.path, owner: Self.recordedOwner(fd))
        }
        descriptor = fd
        if info.st_mode & 0o777 != 0o600 { fchmod(fd, 0o600) }
        // The PID lets a second launch bring this instance forward; the lock itself, not the file, is the truth.
        let record = Array("\(getpid())\n".utf8)
        if ftruncate(fd, 0) == 0 { _ = record.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } }
    }

    deinit { release() }

    /// Gives the lock up early (tests); otherwise it lasts until the process exits.
    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor); descriptor = -1
    }

    private static func recordedOwner(_ fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count > 0, let text = String(bytes: buffer.prefix(count), encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return pid
    }
}

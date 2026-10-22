import Darwin
import Foundation

public enum OwnerOnlyStorageError: Error, Equatable, Sendable {
    /// Not a regular file, or larger than the caller's limit.
    case corrupt
    case io(Int32)
}

/// Owner-only file I/O for Keel's state files: reads never follow symlinks; writes go to an `O_EXCL` 0600 temporary,
/// are synced, renamed over the target, and the directory is synced. Directories are the caller's (0700, MAC-12).
public enum OwnerOnlyStorage {
    /// Nil when the file does not exist. `O_NONBLOCK` keeps a FIFO from hanging the read.
    public static func read(_ url: URL, limit: Int) throws(OwnerOnlyStorageError) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        // A symlink at the final component fails with ELOOP and surfaces as `.io(ELOOP)`.
        if fd < 0 { if errno == ENOENT { return nil }; throw .io(errno) }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw .corrupt }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw .io(errno) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw .corrupt }
        }
    }

    /// `beforeReplace` runs after the temporary is durable and before the rename; tests use it to inject a failure.
    public static func atomicWrite(_ data: Data, to target: URL, temporaryPrefix: String, beforeReplace: (URL) throws -> Void = { _ in }) throws {
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("\(temporaryPrefix)\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw OwnerOnlyStorageError.io(errno) }
        var openDescriptor = true
        defer { if openDescriptor { _ = close(fd) }; _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw OwnerOnlyStorageError.io(errno) }
                guard count > 0 else { throw OwnerOnlyStorageError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw OwnerOnlyStorageError.io(errno) }
        guard close(fd) == 0 else { openDescriptor = false; throw OwnerOnlyStorageError.io(errno) }
        openDescriptor = false
        try beforeReplace(target)
        guard rename(temporary.path, target.path) == 0 else { throw OwnerOnlyStorageError.io(errno) }
        let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { throw OwnerOnlyStorageError.io(errno) }
        defer { _ = close(folder) }
        guard fsync(folder) == 0 else { throw OwnerOnlyStorageError.io(errno) }
    }
}

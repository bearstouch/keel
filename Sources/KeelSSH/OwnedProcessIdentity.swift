import Darwin
import Foundation

/// A PID alone is not enough once a child has been reaped: the number can belong to another process by the time a
/// signal is sent. The launch identity (parent, group and start time) is captured once and revalidated before every
/// signal (Trellis's `OwnedProcessIdentity` rule, 02 Architecture → SSH tunnels).
public struct OwnedProcessIdentity: Equatable, Sendable, Codable {
    public let pid: Int32
    public let parentPID: Int32
    public let groupID: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64

    public init(pid: Int32, parentPID: Int32, groupID: Int32, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid; self.parentPID = parentPID; self.groupID = groupID
        self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
    }

    /// Only a group leader we spawned, still ours and still the same process, may be signalled.
    public func permitsSignal(current: Self?, ownerPID: Int32) -> Bool {
        pid > 0 && parentPID == ownerPID && groupID == pid && current == self
    }

    /// Same process as `other`: pid and start time match. Parent and group may differ (an orphan is reparented to launchd).
    public func isSameProcess(as other: Self?) -> Bool {
        guard let other else { return false }
        return pid == other.pid && startedSeconds == other.startedSeconds && startedMicroseconds == other.startedMicroseconds
    }

    /// The live identity of `pid`, or nil when no such process exists (or it isn't readable).
    public static func read(_ pid: Int32) -> OwnedProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return OwnedProcessIdentity(
            pid: pid, parentPID: Int32(info.pbi_ppid), groupID: Int32(info.pbi_pgid), startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }
}

/// Signals one spawned process group, only while its launch identity still matches and before the child is reaped.
/// `markReaped` and `signal` share a lock, so a reaper can never free the PID between the check and `kill`.
public final class OwnedProcessGroup: @unchecked Sendable {
    public let pid: Int32
    private let launchIdentity: OwnedProcessIdentity?
    private let ownerPID: Int32
    private let readIdentity: @Sendable (Int32) -> OwnedProcessIdentity?
    private let sendSignal: @Sendable (Int32, Int32) -> Void
    private let lock = NSLock()
    private var reaped = false

    public init(
        pid: Int32, ownerPID: Int32 = getpid(), readIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity? = OwnedProcessIdentity.read,
        sendSignal: @escaping @Sendable (Int32, Int32) -> Void = { _ = kill(-$0, $1) }
    ) {
        self.pid = pid; self.ownerPID = ownerPID; self.readIdentity = readIdentity; self.sendSignal = sendSignal
        launchIdentity = readIdentity(pid)
    }

    public var identity: OwnedProcessIdentity? { launchIdentity }

    /// Sends `signal` to the whole group (ssh and any `ProxyCommand` it runs). False when nothing was sent.
    @discardableResult
    public func signal(_ signal: Int32) -> Bool {
        lock.withLock {
            guard !reaped, let launchIdentity, launchIdentity.permitsSignal(current: readIdentity(pid), ownerPID: ownerPID) else { return false }
            sendSignal(pid, signal)
            return true
        }
    }

    /// Runs `reap` (the `waitpid` that frees the PID) under the signal lock; no signal is sent afterwards.
    public func markReaped(_ reap: () -> Void = {}) {
        lock.withLock {
            reap(); reaped = true
        }
    }
}

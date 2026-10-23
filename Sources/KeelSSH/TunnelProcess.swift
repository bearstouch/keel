import Darwin
import Foundation

/// How a tunnel's ssh ended, with its last stderr line made safe to show (FR-CN10 `TUNNEL_FAILED`).
public struct TunnelExit: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case exited(Int32)
        case signaled(Int32)
    }

    public var status: Status
    public var lastErrorLine: String?

    public init(status: Status, lastErrorLine: String?) { self.status = status; self.lastErrorLine = lastErrorLine }

    public init(status: Status, stderr: Data) { self.init(status: status, lastErrorLine: Self.sanitizedLastLine(stderr)) }

    static let lineLimit = 240

    /// The last non-empty line, without terminal escapes or control characters, whitespace collapsed, at most 240
    /// characters. Server banners and ssh messages are untrusted text: nothing in them may restyle or spoof the UI.
    public static func sanitizedLastLine(_ stderr: Data) -> String? {
        let text = String(decoding: stderr, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            var cleaned = ""
            var scalars = line.unicodeScalars.makeIterator()
            while let scalar = scalars.next() {
                if scalar == "\u{1B}" {
                    // CSI `ESC [ … final`, OSC `ESC ] … BEL/ESC` (window titles, links) and two-byte escapes are dropped whole.
                    guard let next = scalars.next() else { break }
                    if next == "[" { while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {} }
                    if next == "]" { while let byte = scalars.next(), byte != "\u{7}", byte != "\u{1B}" {} }
                    continue
                }
                let category = scalar.properties.generalCategory
                if category == .control || category == .format || scalar.value == 0x7F { cleaned.unicodeScalars.append(" "); continue }
                cleaned.unicodeScalars.append(scalar)
            }
            let words = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !words.isEmpty else { continue }
            return words.count > lineLimit ? String(words.prefix(lineLimit - 1)) + "…" : words
        }
        return nil
    }
}

/// A running ssh as the tunnel manager sees it. Injected so tests use fake processes (CLAUDE.md: processes are injected).
public protocol TunnelProcess: AnyObject, Sendable {
    /// The spawned process group; the only way to signal it.
    var group: OwnedProcessGroup { get }
    /// Set once the process has exited and been reaped; never blocks.
    var exit: TunnelExit? { get }
    func waitForExit() async -> TunnelExit
}

public protocol TunnelProcessLauncher: Sendable {
    func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess
}

/// Spawns ssh with `posix_spawn` (no shell): its own session and process group (no controlling terminal, so ssh can never
/// prompt on the terminal Keel was started from), stdin and stdout on `/dev/null`, stderr into a pipe of which only the
/// last 4 KiB is kept, and no other inherited descriptors.
public struct SSHProcessLauncher: TunnelProcessLauncher {
    public init() {}

    public func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess {
        try SpawnedProcess.spawn(executable: executable, arguments: arguments, environment: environment)
    }
}

final class SpawnedProcess: TunnelProcess, @unchecked Sendable {
    static let stderrTail = 4_096
    let group: OwnedProcessGroup
    private let lock = NSLock()
    private var finished: TunnelExit?
    private var waiters: [CheckedContinuation<TunnelExit, Never>] = []
    private var tail = Data()
    private let stderrClosed = DispatchSemaphore(value: 0)

    private init(pid: Int32) { group = OwnedProcessGroup(pid: pid) }

    var exit: TunnelExit? { lock.withLock { finished } }

    func waitForExit() async -> TunnelExit {
        await withCheckedContinuation { continuation in
            let done: TunnelExit? = lock.withLock {
                if let finished { return finished }
                waiters.append(continuation); return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> SpawnedProcess {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw .launchFailed(errno) }
        // Both ends close on exec, so no concurrently spawned process can hold the pipe open; dup2 clears it on fd 2.
        _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC); _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 2)
        // SETSID: new session and group led by ssh, so `kill(-pid)` reaches it and its ProxyCommand children.
        // CLOEXEC_DEFAULT: only the three descriptors above are inherited. SETSIGDEF/SETSIGMASK: a clean signal state.
        var defaults = sigset_t(), empty = sigset_t()
        sigfillset(&defaults); sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attributes, &defaults); posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, executable, &actions, &attributes, argvBuffer.baseAddress, envBuffer.baseAddress)
            }
        }
        close(pipeFDs[1])
        guard status == 0 else { close(pipeFDs[0]); throw .launchFailed(status) }
        let process = SpawnedProcess(pid: pid)
        process.start(stderr: pipeFDs[0])
        return process
    }

    private func start(stderr fd: Int32) {
        let reader = Thread { [self] in readStderr(fd) }
        reader.name = "Keel ssh stderr"
        reader.start()
        let waiter = Thread { [self] in waitForChild() }
        waiter.name = "Keel ssh wait"
        waiter.start()
    }

    private func readStderr(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            lock.withLock {
                tail.append(contentsOf: buffer.prefix(count))
                if tail.count > Self.stderrTail { tail.removeFirst(tail.count - Self.stderrTail) }
            }
        }
        close(fd)
        stderrClosed.signal()
    }

    private func waitForChild() {
        let pid = group.pid
        // Wait without reaping, then reap under the group's signal lock: the PID stays ours until no signal can follow.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) != 0, errno == EINTR {}
        var status: Int32 = 0
        group.markReaped { while waitpid(pid, &status, 0) < 0, errno == EINTR {} }
        // A ProxyCommand child can keep stderr open after ssh exits; don't wait for it for long.
        _ = stderrClosed.wait(timeout: .now() + .milliseconds(500))
        let code = status & 0x7F == 0 ? TunnelExit.Status.exited((status >> 8) & 0xFF) : .signaled(status & 0x7F)
        let (result, waiting) = lock.withLock { () -> (TunnelExit, [CheckedContinuation<TunnelExit, Never>]) in
            let result = TunnelExit(status: code, stderr: tail), waiting = waiters
            finished = result; tail = Data(); waiters = []
            return (result, waiting)
        }
        waiting.forEach { $0.resume(returning: result) }
    }
}

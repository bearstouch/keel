import Darwin
import Foundation
import KeelAskpass

/// Answers `keel-askpass` for ssh tunnels (02 Architecture → SSH tunnels, KEEL-010). One owner-only AF_UNIX socket per
/// app run; each ssh launch registers a random nonce (NFR-SC04). Every request must come from the bundled helper whose
/// parent is that launch's ssh; one that doesn't revokes the nonce, so nothing more is answered for it. The saved
/// password answers the first password prompt only; every other prompt goes to the `PromptRelay` and the person.
public final class AskpassBroker: @unchecked Sendable {
    public struct Registration: Sendable, Equatable {
        public let nonce: String
        public let socketPath: String
        /// What the person was asked during this launch; read by the tunnel manager.
        public let activity: AskpassActivity
        /// Environment for the ssh process; contains no secret.
        public func environment(helper: String) -> [String: String] {
            ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", AskpassProtocol.socketVariable: socketPath, AskpassProtocol.nonceVariable: nonce]
        }

        public static func == (a: Self, b: Self) -> Bool { a.nonce == b.nonce && a.socketPath == b.socketPath }
    }

    private final class Entry: @unchecked Sendable {
        /// The pid of the launch's spawned ssh, read when a request arrives.
        let parent: @Sendable () async -> Int32?
        let destination: String
        let owner = UUID()
        let activity: AskpassActivity
        private let lock = NSLock()
        private var password: (@Sendable () async -> Data?)?

        init(parent: @escaping @Sendable () async -> Int32?, password: (@Sendable () async -> Data?)?, destination: String, activity: AskpassActivity) {
            self.parent = parent; self.password = password; self.destination = destination; self.activity = activity
        }

        /// The saved-password lookup, handed out once: a second password prompt goes to the person (FR-CN06).
        func takePassword() -> (@Sendable () async -> Data?)? {
            lock.withLock {
                defer { password = nil }
                return password
            }
        }
    }

    public static let helperName = AskpassProtocol.helperName
    public let helperPath: String
    private let uid = getuid()
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let relay: PromptRelay?
    private var listenFD: Int32 = -1
    private var directory: String?
    /// Test seam: the peer's executable and parent pid.
    var peerProcess: @Sendable (pid_t) -> (path: String, parent: pid_t)? = AskpassBroker.process

    /// Without a relay every prompt but the saved password is left to the terminal, which a tunnel's ssh doesn't have.
    public init(helperPath: String, relay: PromptRelay? = nil) { self.helperPath = (helperPath as NSString).resolvingSymlinksInPath; self.relay = relay }

    deinit { stop() }

    /// Starts the listener on first use. `password` (the saved password, nil for none) runs at most once; `destination`
    /// names the SSH host in relayed prompts.
    public func register(parent: @escaping @Sendable () async -> Int32?, destination: String = "", password: (@Sendable () async -> Data?)?) -> Registration? {
        lock.withLock {
            guard let path = startLocked() else { return nil }
            let nonce = AskpassProtocol.makeNonce(), activity = AskpassActivity()
            entries[nonce] = Entry(parent: parent, password: password, destination: destination, activity: activity)
            return Registration(nonce: nonce, socketPath: path, activity: activity)
        }
    }

    /// Ends a launch: its nonce gets nothing more and its open prompts are withdrawn from the sheet.
    public func unregister(_ registration: Registration) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: registration.nonce) }) else { return }
        withdrawPrompts(of: entry)
    }

    /// Takes a launch's open prompts off the sheet; they then answer `.cancelled`, which fails them in ssh.
    private func withdrawPrompts(of entry: Entry) {
        if let relay { Task { await relay.withdraw(owner: entry.owner) } }
    }

    var registeredCount: Int { lock.withLock { entries.count } }

    public func stop() {
        let (fd, folder) = lock.withLock { () -> (Int32, String?) in
            defer { listenFD = -1; directory = nil; entries = [:] }
            for entry in entries.values { withdrawPrompts(of: entry) }
            return (listenFD, directory)
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        if let folder { unlink(folder + "/s"); rmdir(folder) }
    }

    private func startLocked() -> String? {
        if listenFD >= 0, let directory { return directory + "/s" }
        // The per-user temporary directory keeps the path short enough for sun_path.
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("keel-askpass-\(AskpassProtocol.makeNonce().prefix(16))")
        guard mkdir(folder, 0o700) == 0 else { return nil }
        let path = folder + "/s"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard fd >= 0, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            if fd >= 0 { close(fd) }
            rmdir(folder)
            return nil
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(path); rmdir(folder)
            return nil
        }
        listenFD = fd; directory = folder
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Keel askpass accept"
        thread.start()
        return path
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
            }
            thread.name = "Keel askpass connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var peerUID: uid_t = 0, peerGID: gid_t = 0, peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == uid,
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID > 0
        else { return }
        guard let header = readHeader(fd), let prompt = readPrompt(fd, length: header.length),
            let entry = lock.withLock({ entries[header.nonce] })
        else {
            // Malformed request or unknown nonce: `I` sends the helper to the terminal, which a tunnel's ssh lacks.
            reply(fd, Data([AskpassProtocol.interactive]))
            return
        }
        let checkPeer = peerProcess, relay = relay
        let helperPath = helperPath, peer = peerPID
        var answer = Self.wait { () async -> Data in
            guard let process = checkPeer(peer), process.path == helperPath, let parent = await entry.parent(), process.parent == parent else {
                // Fail closed for the whole launch: a nonce seen from the wrong process may be known to someone else.
                self.revoke(header.nonce, entry)
                return Data([AskpassProtocol.interactive])
            }
            if header.kind == .password, let password = entry.takePassword() {
                // Touch ID or the Mac password may be on screen: the tunnel's connect deadline waits meanwhile.
                entry.activity.begin(.password)
                let saved = await password()
                entry.activity.end(.password, .accept)
                if var saved {
                    defer { saved.resetBytes(in: 0..<saved.count) }
                    return Data([AskpassProtocol.password]) + saved
                }
            }
            guard let relay else { return Data([AskpassProtocol.interactive]) }
            let question = SSHPrompt(owner: entry.owner, destination: entry.destination, text: prompt, askpass: header.kind)
            entry.activity.begin(question.kind)
            let response = await relay.ask(question)
            entry.activity.end(question.kind, response)
            switch response {
            case .text(var typed):
                defer { typed.resetBytes(in: 0..<typed.count) }
                return Data([AskpassProtocol.password]) + typed
            // ssh's host-key question takes the word `yes`; for a confirm prompt the helper turns it into the exit status.
            case .accept: return Data([AskpassProtocol.password]) + Data("yes".utf8)
            case .decline, .cancelled: return Data([AskpassProtocol.declined])
            }
        }
        defer { answer.resetBytes(in: 0..<answer.count) }
        reply(fd, answer)
    }

    /// Removes the nonce only while it still maps to `entry`; once `unregister` or `stop` took it, they withdrew its prompts.
    private func revoke(_ nonce: String, _ entry: Entry) {
        let removed = lock.withLock { () -> Bool in
            guard entries[nonce] === entry else { return false }
            entries[nonce] = nil; return true
        }
        if removed { withdrawPrompts(of: entry) }
    }

    private func readHeader(_ fd: Int32) -> AskpassProtocol.Header? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < AskpassProtocol.requestLimit, line.last != 0x0A {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { break }
            line.append(byte)
        }
        return AskpassProtocol.header(from: line)
    }

    /// Exactly `length` bytes (bounded by the header check); nil if the helper sent fewer.
    private func readPrompt(_ fd: Int32, length: Int) -> String? {
        var text = [UInt8](repeating: 0, count: length)
        var filled = 0
        while filled < length {
            let count = text.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, length - filled) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            filled += count
        }
        return String(decoding: text, as: UTF8.self)
    }

    private func reply(_ fd: Int32, _ data: Data) {
        var data = data
        defer { data.resetBytes(in: 0..<data.count) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    static func process(_ pid: pid_t) -> (path: String, parent: pid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        return ((path as NSString).resolvingSymlinksInPath, pid_t(info.pbi_ppid))
    }

    /// Bridges a connection thread to async work, like `MCPListener`.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}

/// What happened in the prompts of one ssh launch (KEEL-010): whether the person is being asked something right now
/// (the tunnel's readiness deadline waits meanwhile) and whether a host key was rejected or left unanswered.
public final class AskpassActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private var declined = false

    public init() {}

    /// A prompt is on screen; the readiness deadline doesn't run down while the person reads it.
    public var isAsking: Bool { lock.withLock { open > 0 } }
    /// A host-key prompt was rejected, cancelled or timed out: ssh's failure is "Host key not accepted".
    public var hostKeyDeclined: Bool { lock.withLock { declined } }

    func begin(_ kind: SSHPrompt.Kind) { if kind != .notice { lock.withLock { open += 1 } } }

    func end(_ kind: SSHPrompt.Kind, _ response: SSHPromptResponse) {
        guard kind != .notice else { return }
        lock.withLock {
            open -= 1
            if kind == .hostKey, response != .accept { declined = true }
        }
    }
}

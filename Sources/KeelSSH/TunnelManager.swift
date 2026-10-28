import Darwin
import Foundation

/// Why a tunnel couldn't be opened. Mapped to `TUNNEL_FAILED` / `TIMEOUT` (phase tunnel) in KeelCore (FR-CN10).
public enum TunnelError: Error, Equatable, Sendable {
    case invalidArguments(SSHTunnelArgumentError)
    case runtimeDirectory(RuntimeDirectoryError)
    /// `posix_spawn` failed with this errno; ssh never ran.
    case launchFailed(Int32)
    /// ssh exited before the forward was ready: forward failure (`ExitOnForwardFailure`), authentication, host key.
    case exited(TunnelExit)
    /// The socket didn't accept a connection within the connect timeout; ssh was terminated.
    case timeout(Duration)
    /// The manager shut down (app quitting) while the tunnel was starting.
    case shutDown
    /// The person rejected ssh's host-key prompt, or left it unanswered until it timed out (FR-CN07); ssh then exited.
    case hostKeyNotAccepted(TunnelExit)
    /// The user's ssh_config adds these forwards (`LocalForward …`, from `ssh -G`) for the destination; ssh never ran,
    /// since they would open TCP ports beside Keel's socket (INT-06).
    case configuredForwards([String])
}

/// One user's hold on a tunnel. Release it exactly once; a second release is ignored.
public struct TunnelLease: Hashable, Sendable {
    public let profileID: UUID
    /// The forward's Unix socket; connect with `RedisEndpoint.unixSocket(path:)`.
    public let socketPath: String
    let key: TunnelManager.Key
    let generation: UUID
    let id: UUID
}

/// Runs one `/usr/bin/ssh -N` per profile and configuration, shared by every connection of that profile
/// (02 Architecture → SSH tunnels, FR-CN05, NFR-RS05):
/// - the forward is a Unix socket in the owner-only runtime folder, so no local TCP port is ever opened;
/// - ready means the socket accepts a connection within the connect timeout; ssh exiting first is `exited`;
/// - reference-counted: 10 s after the last lease is released ssh gets SIGTERM, then SIGKILL after 1 s;
/// - every signal goes to ssh's own process group through `OwnedProcessGroup`, so a reused PID is never signalled.
public actor TunnelManager {
    struct Key: Hashable, Sendable {
        let profileID: UUID
        let configuration: SSHTunnelConfiguration
    }

    public struct Options: Sendable {
        public var gracePeriod: Duration
        /// How long ssh has to exit after SIGTERM before the group gets SIGKILL.
        public var terminateTimeout: Duration
        public var pollInterval: Duration
        public init(gracePeriod: Duration = .seconds(10), terminateTimeout: Duration = .seconds(1), pollInterval: Duration = .milliseconds(50)) {
            self.gracePeriod = gracePeriod; self.terminateTimeout = terminateTimeout; self.pollInterval = pollInterval
        }
    }

    private enum State {
        case starting(Task<Result<any TunnelProcess, TunnelError>, Never>)
        case ready
    }

    private struct Tunnel {
        let generation = UUID()
        let socketID = RuntimeDirectory.randomID()
        var state: State
        var process: (any TunnelProcess)?
        var users: Set<UUID> = []
        /// Identifies the pending grace-period close; a newer release or an acquire invalidates it.
        var closeToken: UUID?
    }

    private let launcher: any TunnelProcessLauncher
    private let options: Options
    private let sleep: @Sendable (Duration) async throws -> Void
    private let probe: @Sendable (String) -> Bool
    private let makeRuntime: @Sendable () throws(RuntimeDirectoryError) -> RuntimeDirectory
    private let baseEnvironment: [String: String]
    private let askpass: AskpassBroker?
    private var runtime: RuntimeDirectory?
    private var tunnels: [Key: Tunnel] = [:]
    private var isShutDown = false

    public init(
        launcher: any TunnelProcessLauncher = SSHProcessLauncher(), options: Options = Options(),
        environment: [String: String] = ProcessInfo.processInfo.environment, askpass: AskpassBroker? = nil,
        makeRuntime: @escaping @Sendable () throws(RuntimeDirectoryError) -> RuntimeDirectory = { () throws(RuntimeDirectoryError) in try RuntimeDirectory.create() },
        probe: @escaping @Sendable (String) -> Bool = UnixSocketProbe.accepts,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.launcher = launcher; self.options = options; self.makeRuntime = makeRuntime; self.probe = probe; self.sleep = sleep; self.askpass = askpass
        // An inherited askpass setup would let ssh run a program Keel didn't choose; `askpass` supplies Keel's own.
        baseEnvironment = environment.filter { !$0.key.hasPrefix("SSH_ASKPASS") && $0.key != "DISPLAY" }
    }

    /// Opens (or joins) the tunnel for `profileID`. `environment` is added to ssh's environment. `savedPassword` reads the
    /// host's saved password (`HostLibrary.savedPassword(for:gate:)`); a launch calls it at most once, for ssh's first
    /// password prompt. The connect timeout starts over after the person answers one of ssh's prompts.
    public func acquire(
        profileID: UUID, configuration: SSHTunnelConfiguration, connectTimeout: Duration, environment: [String: String] = [:],
        savedPassword: (@Sendable () async -> Data?)? = nil
    ) async throws(TunnelError) -> TunnelLease {
        let key = Key(profileID: profileID, configuration: configuration)
        let leaseID = UUID()
        while true {
            guard !isShutDown else { throw .shutDown }
            guard let tunnel = tunnels[key] else { break }
            switch tunnel.state {
            case .ready where tunnel.process?.exit == nil:
                join(key, leaseID)
                return lease(key, tunnel, leaseID)
            case .ready:
                // ssh died since it was ready; start a fresh one.
                discard(key)
            case .starting(let task):
                join(key, leaseID)
                if case .failure(let error) = await task.value { throw error }
                // Joined successfully only if the same tunnel is still there and still holds this lease.
                if let current = tunnels[key], current.generation == tunnel.generation, current.users.contains(leaseID) { return lease(key, current, leaseID) }
            }
        }
        var tunnel = Tunnel(state: .ready)
        tunnel.users = [leaseID]
        // The folder is created on the first tunnel only; a socket path that can't fit `sun_path` fails before ssh runs.
        do throws(RuntimeDirectoryError) {
            let directory: RuntimeDirectory
            if let runtime { directory = runtime } else { directory = try makeRuntime(); runtime = directory }
            _ = try directory.socketPath(id: tunnel.socketID)
        } catch {
            throw .runtimeDirectory(error)
        }
        let generation = tunnel.generation
        let task = Task { await self.start(key, generation: generation, connectTimeout: connectTimeout, environment: environment, savedPassword: savedPassword) }
        tunnel.state = .starting(task)
        tunnels[key] = tunnel
        let process: any TunnelProcess
        switch await task.value {
        case .success(let started): process = started
        case .failure(let error): throw error
        }
        // ssh can die between becoming ready and this caller resuming (its exit watcher already forgot the tunnel):
        // report its exit, not a shutdown. No retry here, so an ssh that keeps dying never relaunches in a loop.
        guard let current = tunnels[key], current.generation == generation else { throw isShutDown ? .shutDown : process.exit.map(TunnelError.exited) ?? .shutDown }
        return lease(key, current, leaseID)
    }

    /// Ends one hold. When it was the last, ssh is terminated after the grace period unless a new lease arrives first.
    public func release(_ lease: TunnelLease) {
        guard var tunnel = tunnels[lease.key], tunnel.generation == lease.generation, tunnel.users.remove(lease.id) != nil else { return }
        if tunnel.users.isEmpty, case .ready = tunnel.state { tunnel.closeToken = scheduleClose(lease.key, generation: tunnel.generation) }
        tunnels[lease.key] = tunnel
    }

    /// Terminates every tunnel and removes the runtime folder (app quit). Later acquires fail with `shutDown`.
    public func shutdown() async {
        isShutDown = true
        let running = tunnels
        tunnels = [:]
        await withTaskGroup(of: Void.self) { group in
            for (key, tunnel) in running {
                switch tunnel.state {
                case .starting(let task):
                    // `start` sees `isShutDown`, terminates its ssh and cleans up after itself.
                    group.addTask { _ = await task.value }
                case .ready:
                    group.addTask { await self.terminate(tunnel, key: key) }
                }
            }
        }
        runtime?.remove(); runtime = nil
    }

    /// Number of live leases on the tunnel of `profileID` (all configurations); for tests and diagnostics.
    public func userCount(profileID: UUID) -> Int { tunnels.filter { $0.key.profileID == profileID }.reduce(0) { $0 + $1.value.users.count } }

    // MARK: - Starting

    private func start(_ key: Key, generation: UUID, connectTimeout: Duration, environment: [String: String], savedPassword: (@Sendable () async -> Data?)?) async -> Result<
        any TunnelProcess, TunnelError
    > {
        guard let socketID = tunnels[key]?.socketID else { return .failure(.shutDown) }
        // One nonce per ssh launch; it is revoked as soon as the launch is ready or has failed (no prompt follows `-N`).
        let launched = LaunchedProcessID()
        let registration = askpass?.register(parent: { launched.pid }, destination: key.configuration.destination, password: savedPassword)
        var sshEnvironment = environment
        if let askpass, let registration { sshEnvironment.merge(registration.environment(helper: askpass.helperPath)) { $1 } }
        let result = await launchAndWait(
            key, generation: generation, connectTimeout: connectTimeout, environment: sshEnvironment, activity: registration?.activity, launched: launched)
        if let registration { askpass?.unregister(registration) }
        guard case .success(let process) = result else {
            if tunnels[key]?.generation == generation { tunnels[key] = nil }
            return result
        }
        // Nothing can suspend between the last shutdown check in `launchAndWait` and here, but never leave a ready ssh behind.
        guard tunnels[key]?.generation == generation else { await stop(process, socketID: socketID); return .failure(.shutDown) }
        tunnels[key]?.state = .ready
        tunnels[key]?.process = process
        if tunnels[key]?.users.isEmpty == true { tunnels[key]?.closeToken = scheduleClose(key, generation: generation) }
        watchExit(process, key: key, generation: generation)
        return .success(process)
    }

    private func launchAndWait(
        _ key: Key, generation: UUID, connectTimeout: Duration, environment: [String: String], activity: AskpassActivity?, launched: LaunchedProcessID
    ) async -> Result<any TunnelProcess, TunnelError> {
        guard let runtime, let socketID = tunnels[key]?.socketID else { return .failure(.shutDown) }
        let path: String, arguments: [String]
        do throws(RuntimeDirectoryError) { path = try runtime.socketPath(id: socketID) } catch { return .failure(.runtimeDirectory(error)) }
        do throws(SSHTunnelArgumentError) { arguments = try SSHTunnelArguments.arguments(for: key.configuration, socketPath: path) } catch { return .failure(.invalidArguments(error)) }
        let sshEnvironment = baseEnvironment.merging(environment) { $1 }
        // `ssh -G` resolves the same arguments against the user's config without connecting. Unreadable output isn't
        // fatal: the launch below reports ssh's own error.
        if let options = await launcher.effectiveOptions(executable: SSHTunnelArguments.executable, arguments: ["-G"] + arguments, environment: sshEnvironment, timeout: connectTimeout) {
            let forwards = SSHTunnelArguments.configuredForwards(in: options, socketPath: path)
            guard forwards.isEmpty else { return .failure(.configuredForwards(forwards)) }
        }
        if isShutDown || tunnels[key]?.generation != generation { return .failure(.shutDown) }
        let process: any TunnelProcess
        do throws(TunnelError) {
            process = try launcher.launch(executable: SSHTunnelArguments.executable, arguments: arguments, environment: sshEnvironment)
        } catch {
            return .failure(error)
        }
        launched.pid = process.group.pid
        // Record the ssh so a crashed run's tunnel is terminated on the next launch; a failed record isn't fatal.
        if let identity = process.group.identity { try? runtime.writeRecord(identity, named: runtime.recordName(id: socketID)) }
        // A rejected host key makes ssh exit; report the person's decision, not ssh's generic failure.
        let exited = { (exit: TunnelExit) -> TunnelError in activity?.hostKeyDeclined == true ? .hostKeyNotAccepted(exit) : .exited(exit) }
        var attempts = 0
        let limit = pollAttempts(within: connectTimeout)
        while attempts < limit {
            if let exit = process.exit { runtime.removeTunnelFiles(id: socketID); return .failure(exited(exit)) }
            if isShutDown || tunnels[key]?.generation != generation { await stop(process, socketID: socketID); return .failure(.shutDown) }
            if probe(path) { return .success(process) }
            // While a prompt is on screen the deadline starts over, so ssh gets the full connect timeout after the
            // answer to finish authenticating; the relay's own timeout bounds the wait for the person.
            if activity?.isAsking == true { attempts = 0 } else { attempts += 1 }
            try? await sleep(options.pollInterval)
        }
        await stop(process, socketID: socketID)
        // ssh may have failed right at the deadline; its own reason beats a generic timeout.
        if let exit = process.exit, case .exited(let code) = exit.status, code != 0 { return .failure(exited(exit)) }
        return .failure(.timeout(connectTimeout))
    }

    // MARK: - Closing

    private func scheduleClose(_ key: Key, generation: UUID) -> UUID {
        let token = UUID()
        let grace = options.gracePeriod, sleep = sleep
        Task {
            try? await sleep(grace)
            await self.closeIfIdle(key, generation: generation, token: token)
        }
        return token
    }

    private func closeIfIdle(_ key: Key, generation: UUID, token: UUID) async {
        guard let tunnel = tunnels[key], tunnel.generation == generation, tunnel.closeToken == token, tunnel.users.isEmpty else { return }
        tunnels[key] = nil
        await terminate(tunnel, key: key)
    }

    /// ssh exited on its own (network drop, server closed): forget it so the next acquire starts a new one.
    private func watchExit(_ process: any TunnelProcess, key: Key, generation: UUID) {
        Task {
            _ = await process.waitForExit()
            self.exited(key, generation: generation)
        }
    }

    private func exited(_ key: Key, generation: UUID) {
        guard tunnels[key]?.generation == generation else { return }
        discard(key)
    }

    private func discard(_ key: Key) {
        guard let tunnel = tunnels.removeValue(forKey: key) else { return }
        runtime?.removeTunnelFiles(id: tunnel.socketID)
    }

    private func terminate(_ tunnel: Tunnel, key: Key) async {
        if let process = tunnel.process { await stop(process, socketID: tunnel.socketID) } else { runtime?.removeTunnelFiles(id: tunnel.socketID) }
    }

    /// SIGTERM to the group, SIGKILL if still running after `terminateTimeout`. Both go through the identity check.
    private func stop(_ process: any TunnelProcess, socketID: String) async {
        if process.exit == nil, process.group.signal(SIGTERM) {
            for _ in 0..<pollAttempts(within: options.terminateTimeout) where process.exit == nil { try? await sleep(options.pollInterval) }
            if process.exit == nil { process.group.signal(SIGKILL) }
        }
        runtime?.removeTunnelFiles(id: socketID)
    }

    /// Adds a lease to an existing tunnel and cancels its pending close.
    private func join(_ key: Key, _ leaseID: UUID) {
        tunnels[key]?.users.insert(leaseID); tunnels[key]?.closeToken = nil
    }

    private func pollAttempts(within timeout: Duration) -> Int { max(1, Int((timeout / options.pollInterval).rounded(.up))) }

    private func lease(_ key: Key, _ tunnel: Tunnel, _ id: UUID) -> TunnelLease {
        TunnelLease(profileID: key.profileID, socketPath: (try? runtime?.socketPath(id: tunnel.socketID)) ?? "", key: key, generation: tunnel.generation, id: id)
    }
}

/// The pid of a launch's ssh once spawned; the askpass broker reads it to check a helper's parent.
final class LaunchedProcessID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var pid: Int32? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Readiness and peer check for a tunnel socket (NFR-SC04): the path must be a socket owned by this user (never a
/// symlink), accept a connection, and the peer must run as this user. The probe connection is closed at once.
public enum UnixSocketProbe {
    public static func accepts(_ path: String) -> Bool {
        guard RuntimeDirectory.isOwnedSocket(path) else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        var uid: uid_t = 0, gid: gid_t = 0
        return connected == 0 && getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}

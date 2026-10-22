import Foundation
import Network
import os

/// Where a Redis server listens. SSH tunnels forward to a Unix socket (02 Architecture → SSH tunnels).
public enum RedisEndpoint: Sendable, Equatable {
    case tcp(host: String, port: UInt16)
    case unixSocket(path: String)
}

/// The byte stream under a `RedisConnection`; `NetworkTransport` in the app, in-memory fakes in tests.
///
/// `send` is synchronous so bytes reach the stream in the order the connection queued their replies; an async
/// send would let the actor interleave two callers between queuing and writing. `receive` is pulled one chunk at a
/// time, so a fast server can't buffer unbounded data ahead of the parser.
public protocol Transport: Sendable {
    /// Returns once the stream is ready. Cancelling the transport makes a pending call fail with `.cancelled`.
    func connect() async throws(TransportError)
    /// Queues bytes for writing. A failed write ends the stream, which the next `receive` reports.
    func send(_ data: Data)
    /// The next chunk of bytes, never empty; throws `.closed` at end of stream.
    func receive() async throws(TransportError) -> Data
    /// Closes the stream and fails any pending `connect` or `receive`. Idempotent.
    func cancel()
    /// Nil without TLS; false when TLS skips verification, which the UI must show in text (NFR-SC02).
    var tlsVerified: Bool? { get }
    /// After a failed TLS connect: whether the endpoint answers a plain `PING` with RESP, i.e. isn't using TLS.
    /// Opens its own short-lived plain connection; false for transports without TLS.
    func answersPlainRESP() async -> Bool
}

extension Transport {
    public var tlsVerified: Bool? { nil }
    public func answersPlainRESP() async -> Bool { false }
}

/// `Transport` over one `NWConnection`: TCP or Unix socket, with or without TLS.
public final class NetworkTransport: Transport {
    private let connection: NWConnection
    private let endpoint: NWEndpoint
    private let queue: DispatchQueue
    private let state: OSAllocatedUnfairLock<Shared>
    public let tlsVerified: Bool?

    private struct Shared {
        var started = false
        var cancelled = false
        var connectWaiter: CheckedContinuation<Result<Void, TransportError>, Never>?
        /// Set by the verify block; Network then fails with a bare OSStatus, so this says which check refused.
        var trustFailure: TLSTrustFailure?
    }

    /// TCP with Nagle off, which Redis pipelining wants, under TLS when `tls` is set (02 Architecture → TLS).
    public convenience init(endpoint: RedisEndpoint, tls: TLSConfiguration? = nil) {
        let state = OSAllocatedUnfairLock(initialState: Shared())
        let queue = DispatchQueue(label: Self.queueLabel)
        let tlsOptions = tls?.makeOptions(for: endpoint, queue: queue) { failure in state.withLock { $0.trustFailure = failure } }
        self.init(endpoint: endpoint, parameters: NWParameters(tls: tlsOptions, tcp: Self.tcpOptions()), queue: queue, state: state, tlsVerified: tls.map { !$0.skipVerification })
    }

    /// For callers that build their own `NWParameters`; `tlsVerified` is then unknown, so nil.
    public convenience init(endpoint: RedisEndpoint, parameters: NWParameters) {
        self.init(
            endpoint: endpoint, parameters: parameters, queue: DispatchQueue(label: Self.queueLabel), state: OSAllocatedUnfairLock(initialState: Shared()), tlsVerified: nil)
    }

    private init(endpoint: RedisEndpoint, parameters: NWParameters, queue: DispatchQueue, state: OSAllocatedUnfairLock<Shared>, tlsVerified: Bool?) {
        self.queue = queue; self.state = state; self.tlsVerified = tlsVerified
        self.endpoint = Self.nwEndpoint(endpoint)
        connection = NWConnection(to: self.endpoint, using: parameters)
    }

    private static let queueLabel = "com.bearstouch.keel.resp.transport"

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return tcp
    }

    private static func nwEndpoint(_ endpoint: RedisEndpoint) -> NWEndpoint {
        switch endpoint {
        case .tcp(let host, let port): return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .unixSocket(let path): return .unix(path: path)
        }
    }

    public func connect() async throws(TransportError) {
        let result = await withCheckedContinuation { (waiter: CheckedContinuation<Result<Void, TransportError>, Never>) in
            let refused: TransportError? = state.withLock { shared in
                if shared.cancelled { return .cancelled }
                if shared.started { return .other }
                shared.started = true; shared.connectWaiter = waiter
                return nil
            }
            if let refused { waiter.resume(returning: .failure(refused)); return }
            connection.stateUpdateHandler = { [weak self] update in self?.handle(update) }
            connection.start(queue: queue)
        }
        try result.get()
    }

    private func handle(_ update: NWConnection.State) {
        let outcome: Result<Void, TransportError>
        switch update {
        case .ready: outcome = .success(())
        // `.waiting` would retry forever (e.g. connection refused); a Redis client wants the error now.
        case .waiting(let error), .failed(let error): outcome = .failure(Self.map(error, refused: state.withLock { $0.trustFailure }))
        case .cancelled: outcome = .failure(.cancelled)
        default: return
        }
        let waiter = state.withLock { shared in
            defer { shared.connectWaiter = nil }
            return shared.connectWaiter
        }
        // A failed or waiting connection keeps its resources until cancelled.
        if case .failure = outcome, update != .cancelled { connection.cancel() }
        waiter?.resume(returning: outcome)
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [connection] error in if error != nil { connection.cancel() } })
    }

    public func receive() async throws(TransportError) -> Data {
        if state.withLock({ $0.cancelled }) { throw .cancelled }
        let result = await withCheckedContinuation { [state] (waiter: CheckedContinuation<Result<Data, TransportError>, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                // Deliver bytes before an end-of-stream that came with them; the next call reports the end.
                if let data, !data.isEmpty {
                    waiter.resume(returning: .success(data))
                } else if let error {
                    waiter.resume(returning: .failure(Self.map(error, refused: state.withLock { $0.trustFailure })))
                } else if isComplete {
                    waiter.resume(returning: .failure(.closed))
                } else {
                    // No bytes, error or end: Network shouldn't do this, but a waiter must never be left hanging.
                    waiter.resume(returning: .failure(.other))
                }
            }
        }
        return try result.get()
    }

    public func cancel() {
        let waiter = state.withLock { shared in
            defer { shared.cancelled = true; shared.connectWaiter = nil }
            return shared.connectWaiter
        }
        connection.cancel()
        waiter?.resume(returning: .failure(.cancelled))
    }

    /// A plain connection that sends `PING` and looks at the first reply byte (`+PONG`, or `-NOAUTH` from a
    /// protected server), within 2 s. A Redis server reads a TLS ClientHello as an unfinished inline command and
    /// never answers it, so this is the only way to tell "not TLS" from a slow server.
    public func answersPlainRESP() async -> Bool {
        guard tlsVerified != nil else { return false }
        let probe = PlainProbe(connection: NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: Self.tcpOptions())))
        return await withCheckedContinuation { waiter in probe.run(on: queue, waiter) }
    }

    /// Whatever status Network reports after the verify block said no, the refusal (`refused`) is the useful answer.
    private static func map(_ error: NWError, refused: TLSTrustFailure?) -> TransportError {
        if let refused { return .tlsRejected(refused) }
        switch error {
        case .posix(let code): return code == .ECANCELED ? .cancelled : .posix(code.rawValue)
        case .dns(let code): return .dns(code)
        case .tls(let status): return .tls(status)
        default: return .other
        }
    }
}

/// One `answersPlainRESP` attempt. Every path ends in `finish`, which resumes the waiter exactly once.
private final class PlainProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let waiter = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)

    init(connection: NWConnection) { self.connection = connection }

    func run(on queue: DispatchQueue, _ continuation: CheckedContinuation<Bool, Never>) {
        waiter.withLock { $0 = continuation }
        connection.stateUpdateHandler = { [self] update in
            switch update {
            case .ready:
                connection.send(content: RESPEncoder.command([Data("PING".utf8)]), completion: .idempotent)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [self] data, _, _, _ in
                    finish(data?.first == UInt8(ascii: "+") || data?.first == UInt8(ascii: "-"))
                }
            case .waiting, .failed, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [self] in finish(false) }
    }

    private func finish(_ answered: Bool) {
        guard let continuation = waiter.withLock({ $0.take() }) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: answered)
    }
}

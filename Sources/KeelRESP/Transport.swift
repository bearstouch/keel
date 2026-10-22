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
}

/// `Transport` over one `NWConnection` (TCP or Unix socket; TLS arrives through `parameters`).
public final class NetworkTransport: Transport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.bearstouch.keel.resp.transport")
    private let state = OSAllocatedUnfairLock(initialState: Shared())

    private struct Shared {
        var started = false
        var cancelled = false
        var connectWaiter: CheckedContinuation<Result<Void, TransportError>, Never>?
    }

    /// `parameters` defaults to TCP with Nagle off, which Redis pipelining wants.
    public init(endpoint: RedisEndpoint, parameters: NWParameters? = nil) {
        let nwEndpoint: NWEndpoint
        switch endpoint {
        case .tcp(let host, let port): nwEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .unixSocket(let path): nwEndpoint = .unix(path: path)
        }
        connection = NWConnection(to: nwEndpoint, using: parameters ?? Self.defaultParameters())
    }

    private static func defaultParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
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
        case .waiting(let error), .failed(let error): outcome = .failure(Self.map(error))
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
        let result = await withCheckedContinuation { (waiter: CheckedContinuation<Result<Data, TransportError>, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                // Deliver bytes before an end-of-stream that came with them; the next call reports the end.
                if let data, !data.isEmpty {
                    waiter.resume(returning: .success(data))
                } else if let error {
                    waiter.resume(returning: .failure(Self.map(error)))
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

    private static func map(_ error: NWError) -> TransportError {
        switch error {
        case .posix(let code): return code == .ECANCELED ? .cancelled : .posix(code.rawValue)
        case .dns(let code): return .dns(code)
        case .tls(let status): return .tls(status)
        default: return .other
        }
    }
}

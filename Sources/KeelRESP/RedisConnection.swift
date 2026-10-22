import Foundation

/// One socket to one server (02 Architecture → Connections). Commands are written as soon as they are sent and
/// their replies are matched in order from a FIFO, so any number can be in flight (pipelining).
///
/// A connection is single-use: `connect()` once; after it fails or closes, open a new one. Nothing is ever
/// retried or re-sent here. When the connection ends with commands in flight, writes fail with `OUTCOME_UNKNOWN`
/// (NFR-RL03), and a late reply can never reach another command because a command that times out closes the
/// connection. No bytes of arguments or replies are logged.
public actor RedisConnection {
    public enum State: Sendable, Equatable {
        case idle, connecting, ready
        /// Ended on its own: connect failure, drop, timeout or a broken reply stream.
        case failed(RedisError)
        /// Closed by `close()`.
        case closed
    }

    public struct Options: Sendable, Equatable {
        public var connectTimeout: Duration
        /// Default per-command timeout; `send(_:mayWrite:timeout:)` can override it.
        public var commandTimeout: Duration
        public var limits: RESPLimits

        public init(connectTimeout: Duration = .seconds(10), commandTimeout: Duration = .seconds(30), limits: RESPLimits = .standard) {
            self.connectTimeout = connectTimeout; self.commandTimeout = commandTimeout; self.limits = limits
        }
    }

    public private(set) var state: State = .idle
    public nonisolated let options: Options
    /// RESP3 push messages; they never consume a command's reply. Holds the newest 256 when nobody listens.
    public nonisolated let pushes: AsyncStream<RESPValue>

    private nonisolated let transport: any Transport
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pushSink: AsyncStream<RESPValue>.Continuation
    private var parser: RESPParser
    private var readLoop: Task<Void, Never>?

    /// Commands awaiting replies, oldest first, from `head` on. IDs are consecutive and slots leave only from the
    /// front, so a command's slot is at `head + (id - firstID)`.
    private var pending: [Pending] = []
    private var head = 0
    private var nextID: UInt64 = 0

    private struct Pending {
        let id: UInt64
        let mayWrite: Bool
        /// Nil once the caller stopped waiting; the slot stays so the reply, when it comes, is dropped in order.
        var waiter: CheckedContinuation<Result<RESPValue, RedisError>, Never>?
        var timer: Task<Void, Never>?
    }

    /// `sleep` drives the connect and command timeouts; tests inject a manual one.
    public init(transport: any Transport, options: Options = Options(), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport; self.options = options; self.sleep = sleep
        parser = RESPParser(limits: options.limits)
        (pushes, pushSink) = AsyncStream.makeStream(of: RESPValue.self, bufferingPolicy: .bufferingNewest(256))
    }

    public init(endpoint: RedisEndpoint, options: Options = Options()) {
        self.init(transport: NetworkTransport(endpoint: endpoint), options: options)
    }

    deinit { transport.cancel() }

    // MARK: - Lifecycle

    /// Opens the stream within `options.connectTimeout`.
    public func connect() async throws(RedisError) {
        guard state == .idle else { throw .notConnected }
        state = .connecting
        let timer = Task { [weak self, sleep, options] in
            do { try await sleep(options.connectTimeout) } catch { return }
            await self?.connectTimedOut()
        }
        defer { timer.cancel() }
        let result: Result<Void, TransportError>
        do {
            try await withTaskCancellationHandler {
                try await transport.connect()
            } onCancel: { [transport] in
                transport.cancel()
            }
            result = .success(())
        } catch { result = .failure(error as? TransportError ?? .other) }
        // A timeout or close() while connecting already moved the state on and cancelled the transport.
        switch state {
        case .connecting: break
        case .failed(let error): throw error
        default: throw .cancelled
        }
        switch result {
        // The caller's task was cancelled (its handler cancelled the transport, even if connect won the race):
        // not a server failure, and never `ready` over a cancelled transport.
        case _ where Task.isCancelled:
            end(.closed, readsFail: .cancelled)
            throw .cancelled
        case .success:
            state = .ready
            startReading()
        case .failure(let error):
            end(.failed(.connectionFailed(error)), readsFail: .connectionLost)
            throw .connectionFailed(error)
        }
    }

    /// Closes the socket. In-flight reads fail with `CANCELLED`, sent writes with `OUTCOME_UNKNOWN`.
    public func close() {
        switch state {
        case .failed, .closed: return
        default: end(.closed, readsFail: .cancelled)
        }
    }

    private func connectTimedOut() {
        guard state == .connecting else { return }
        end(.failed(.timeout(.connect)), readsFail: .connectionLost)
    }

    /// The one way out of `connecting`/`ready`: stops the socket and settles every waiting command.
    private func end(_ final: State, readsFail readError: RedisError) {
        state = final
        transport.cancel()
        readLoop?.cancel(); readLoop = nil
        let settled = pending[head...]
        pending = []; head = 0
        for slot in settled {
            slot.timer?.cancel()
            slot.waiter?.resume(returning: .failure(slot.mayWrite ? .outcomeUnknown : readError))
        }
        pushSink.finish()
    }

    // MARK: - Commands

    /// Sends one command and waits for its reply, which may be a server error value (`-ERR …`).
    ///
    /// `mayWrite` decides what an interrupted command reports: `OUTCOME_UNKNOWN` for a possible write, otherwise
    /// `CONNECTION_FAILED` or `CANCELLED`. It defaults to true so an unclassified command fails closed. A command
    /// that exceeds `timeout` fails with `TIMEOUT` and closes the connection. Throws `NOT_CONNECTED`, sending
    /// nothing, unless the connection is ready.
    public func send(_ arguments: [Data], mayWrite: Bool = true, timeout: Duration? = nil) async throws(RedisError) -> RESPValue {
        guard state == .ready else { throw .notConnected }
        guard !Task.isCancelled else { throw .cancelled }
        let id = nextID
        let frame = RESPEncoder.command(arguments)
        let limit = timeout ?? options.commandTimeout
        // Both closures below run on this actor before any suspension, so the slot exists before a cancellation
        // handler can look for it and before the reply can arrive.
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Result<RESPValue, RedisError>, Never>) in
                nextID += 1
                pending.append(Pending(id: id, mayWrite: mayWrite, waiter: waiter, timer: startTimer(id, limit)))
                transport.send(frame)
            }
        } onCancel: {
            Task { await self.callerCancelled(id) }
        }
        return try result.get()
    }

    private func startTimer(_ id: UInt64, _ limit: Duration) -> Task<Void, Never> {
        Task { [weak self, sleep] in
            do { try await sleep(limit) } catch { return }
            await self?.commandTimedOut(id)
        }
    }

    private func slotIndex(_ id: UInt64) -> Int? {
        guard head < pending.count, id >= pending[head].id else { return nil }
        let index = head + Int(id - pending[head].id)
        return index < pending.count ? index : nil
    }

    /// Resumes the slot's caller, if still waiting, and keeps the slot so its reply is later dropped in order.
    private func fail(_ index: Int, _ error: RedisError) {
        pending[index].waiter?.resume(returning: .failure(error))
        pending[index].waiter = nil
    }

    private func callerCancelled(_ id: UInt64) {
        guard let index = slotIndex(id) else { return }
        fail(index, pending[index].mayWrite ? .outcomeUnknown : .cancelled)
    }

    private func commandTimedOut(_ id: UInt64) {
        guard state == .ready, let index = slotIndex(id) else { return }
        // Its reply may still come; closing is the only way to keep it from being read as the next command's.
        fail(index, .timeout(.command))
        end(.failed(.timeout(.command)), readsFail: .connectionLost)
    }

    // MARK: - Replies

    private func startReading() {
        readLoop = Task { [weak self, transport] in
            while !Task.isCancelled {
                let chunk: Result<Data, TransportError>
                do throws(TransportError) { chunk = .success(try await transport.receive()) } catch { chunk = .failure(error) }
                guard let self, await self.ingest(chunk) else { return }
            }
        }
    }

    /// Feeds one chunk to the parser and hands out every reply it completes. Returns false once reading is over.
    private func ingest(_ chunk: Result<Data, TransportError>) -> Bool {
        guard state == .ready else { return false }
        switch chunk {
        case .failure(let error):
            end(.failed(.connectionFailed(error)), readsFail: .connectionLost)
            return false
        case .success(let bytes):
            parser.append(bytes)
            do {
                while let reply = try parser.next() {
                    if case .push = reply { pushSink.yield(reply); continue }
                    guard deliver(reply) else { return false }
                }
            } catch {
                // The head's reply was the broken one; a write there may still have run on the server.
                if head < pending.count, !pending[head].mayWrite { fail(head, .codec(error)) }
                end(.failed(.codec(error)), readsFail: .connectionLost)
                return false
            }
            return true
        }
    }

    private func deliver(_ reply: RESPValue) -> Bool {
        guard head < pending.count else {
            end(.failed(.unexpectedReply), readsFail: .connectionLost)
            return false
        }
        let slot = pending[head]
        head += 1
        slot.timer?.cancel()
        slot.waiter?.resume(returning: .success(reply))
        // Compact now and then so a long-lived pipelined connection doesn't grow `pending` without bound.
        if head == pending.count {
            pending.removeAll(keepingCapacity: pending.capacity <= 4_096); head = 0
        } else if head >= 1_024, head * 2 >= pending.count {
            pending.removeSubrange(0..<head); head = 0
        }
        return true
    }
}

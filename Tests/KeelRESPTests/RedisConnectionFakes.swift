import Foundation
import XCTest
@testable import KeelRESP

/// In-memory `Transport`: records every frame sent (even after cancel, so a stray send is caught) and lets the test
/// play the server by queuing reply chunks and drops.
final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Result<Data, TransportError>] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    private var connectWaiter: CheckedContinuation<Result<Void, TransportError>, Never>?
    private var frames: [Data] = []
    private var cancelled = false
    private let connectFailure: TransportError?
    private let holdConnect: Bool
    /// Called after each send, outside the lock, with the frames so far.
    private let onSend: (@Sendable (FakeTransport, [Data]) -> Void)?

    init(connectFailure: TransportError? = nil, holdConnect: Bool = false, onSend: (@Sendable (FakeTransport, [Data]) -> Void)? = nil) {
        self.connectFailure = connectFailure; self.holdConnect = holdConnect; self.onSend = onSend
    }

    var sent: [Data] { lock.withLock { frames } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    /// Sent frames decoded back into their arguments.
    var commands: [[String]] {
        sent.map { frame in
            var parser = RESPParser()
            parser.append(frame)
            guard case .array(let items)? = try? parser.next() else { return [] }
            return items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }
        }
    }

    func connect() async throws(TransportError) {
        if let connectFailure { throw connectFailure }
        if !holdConnect { if isCancelled { throw .cancelled }; return }
        let result = await withCheckedContinuation { waiter in
            let cancelled = lock.withLock {
                if !self.cancelled { connectWaiter = waiter }
                return self.cancelled
            }
            if cancelled { waiter.resume(returning: .failure(.cancelled)) }
        }
        try result.get()
    }

    func send(_ data: Data) {
        let all = lock.withLock {
            frames.append(data); return frames
        }
        onSend?(self, all)
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let ready: Result<Data, TransportError>? = lock.withLock {
                if !chunks.isEmpty { return chunks.removeFirst() }
                if cancelled { return .failure(.cancelled) }
                receiver = waiter
                return nil
            }
            if let ready { waiter.resume(returning: ready) }
        }
        return try result.get()
    }

    func cancel() {
        let (receiver, connectWaiter) = lock.withLock {
            defer { cancelled = true; self.receiver = nil; self.connectWaiter = nil }
            return (self.receiver, self.connectWaiter)
        }
        receiver?.resume(returning: .failure(.cancelled))
        connectWaiter?.resume(returning: .failure(.cancelled))
    }

    /// Server bytes, delivered as one chunk.
    func reply(_ text: String) { push(.success(bytes(text))) }
    func reply(_ bytes: Data) { push(.success(bytes)) }
    /// The socket ends.
    func drop(_ error: TransportError = .closed) { push(.failure(error)) }

    private func push(_ chunk: Result<Data, TransportError>) {
        let waiter: CheckedContinuation<Result<Data, TransportError>, Never>? = lock.withLock {
            if let receiver { self.receiver = nil; return receiver }
            chunks.append(chunk)
            return nil
        }
        waiter?.resume(returning: chunk)
    }
}

/// An injected clock: every `sleep` parks until the test fires its duration, and throws when its task is cancelled.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [UUID: (duration: Duration, waiter: CheckedContinuation<Void, any Error>)] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                // Read cancellation once: reading it again could see a cancel whose handler already resumed `waiter`.
                let cancelled = lock.withLock {
                    let cancelled = Task.isCancelled
                    if !cancelled { sleepers[id] = (duration, waiter) }
                    return cancelled
                }
                if cancelled { waiter.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.waiter.resume(throwing: CancellationError())
        }
    }

    func count(_ duration: Duration) -> Int { lock.withLock { sleepers.values.filter { $0.duration == duration }.count } }

    /// Wakes every sleeper of `duration`.
    func fire(_ duration: Duration) {
        let due = lock.withLock {
            let due = sleepers.filter { $0.value.duration == duration }
            for key in due.keys { sleepers.removeValue(forKey: key) }
            return due.values.map(\.waiter)
        }
        for waiter in due { waiter.resume() }
    }
}

/// Polls `condition` until it holds or a few seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

func bytes(_ text: String) -> Data { Data(text.utf8) }

/// A real Unix-socket server on a temporary path that answers `+PONG` to `PING` and echoes `ECHO`.
final class UnixSocketServer: @unchecked Sendable {
    let path: String
    private let listener: Int32

    init() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("keel-\(UUID().uuidString.prefix(8)).sock").path
        self.path = path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { Darwin.close(listener); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8); raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 4) == 0 else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        self.listener = listener
        Thread.detachNewThread { Self.serve(listener) }
    }

    private static func serve(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { answer(client) }
        }
    }

    private static func answer(_ client: Int32) {
        defer { Darwin.close(client) }
        var parser = RESPParser()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            parser.append(chunk[0..<count])
            var out = Data()
            while case .array(let items)? = try? parser.next() {
                let arguments = items.compactMap { if case .bulkString(let bytes) = $0 { bytes } else { nil } }
                if arguments.first == bytes("ECHO"), arguments.count == 2 {
                    out.append(bytes("$\(arguments[1].count)\r\n")); out.append(arguments[1]); out.append(bytes("\r\n"))
                } else {
                    out.append(bytes("+PONG\r\n"))
                }
            }
            let written = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard written == out.count else { return }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR); Darwin.close(listener)
        unlink(path)
    }
}

import Foundation
import KeelRESP

@testable import KeelCore

/// In-memory server: records every frame written (the protocol trace) and answers each command at once with
/// `answer(arguments)`, `+OK` by default.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Result<Data, TransportError>, Never>?
    private var cancelled = false
    private let answer: @Sendable ([String]) -> String

    init(answer: @escaping @Sendable ([String]) -> String = { _ in "+OK\r\n" }) { self.answer = answer }

    var sent: [Data] { lock.withLock { frames } }
    /// Sent frames decoded back into their arguments.
    var commands: [[String]] { sent.map { Self.decode($0) ?? [] } }

    /// A command frame's arguments as text; nil when the frame isn't a RESP array.
    private static func decode(_ frame: Data) -> [String]? {
        var parser = RESPParser()
        parser.append(frame)
        guard case .array(let items)? = try? parser.next() else { return nil }
        return items.map { if case .bulkString(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { "?" } }
    }

    func connect() async throws(TransportError) { if lock.withLock({ cancelled }) { throw .cancelled } }

    func send(_ data: Data) {
        let reply: Data = lock.withLock {
            frames.append(data)
            guard let arguments = Self.decode(data) else { return Data("-ERR fake\r\n".utf8) }
            return Data(answer(arguments).utf8)
        }
        deliver(reply)
    }

    func receive() async throws(TransportError) -> Data {
        let result = await withCheckedContinuation { waiter in
            let ready: Result<Data, TransportError>? = lock.withLock {
                if !pending.isEmpty { return .success(pending.removeFirst()) }
                if cancelled { return .failure(.cancelled) }
                receiver = waiter
                return nil
            }
            if let ready { waiter.resume(returning: ready) }
        }
        return try result.get()
    }

    func cancel() {
        let waiter = lock.withLock {
            defer { cancelled = true; receiver = nil }
            return receiver
        }
        waiter?.resume(returning: .failure(.cancelled))
    }

    private func deliver(_ bytes: Data) {
        let waiter: CheckedContinuation<Result<Data, TransportError>, Never>? = lock.withLock {
            if let receiver { self.receiver = nil; return receiver }
            pending.append(bytes)
            return nil
        }
        waiter?.resume(returning: .success(bytes))
    }
}

/// A session whose opener makes a `RecordingTransport` connection per role and remembers what it opened.
final class RecordingServer: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [(ConnectionRole, Int, RecordingTransport)] = []
    private let answer: @Sendable ([String]) -> String

    init(answer: @escaping @Sendable ([String]) -> String = { _ in "+OK\r\n" }) { self.answer = answer }

    /// Every connection opened, in order: role, database at open, and its trace.
    var opened: [(role: ConnectionRole, database: Int, transport: RecordingTransport)] { lock.withLock { transports.map { ($0.0, $0.1, $0.2) } } }
    /// Every command sent on any connection.
    var allCommands: [[String]] { opened.flatMap { $0.transport.commands } }

    func session() -> ServerSession {
        ServerSession { (role: ConnectionRole, database: Int) async throws(ConnectionFailure) -> RedisConnection in
            let transport = RecordingTransport(answer: self.answer)
            self.lock.withLock { self.transports.append((role, database, transport)) }
            let connection = RedisConnection(transport: transport)
            do throws(RedisError) { try await connection.connect() } catch {
                throw ConnectionFailure(category: .connectionFailed, message: "fake connect failed", suggestion: "")
            }
            return connection
        }
    }
}

func args(_ words: String...) -> [Data] { words.map { Data($0.utf8) } }

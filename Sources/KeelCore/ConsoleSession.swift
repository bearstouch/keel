import Foundation
import KeelRESP

/// One line of console output and how it is drawn (08 Design → Console).
public struct ConsoleLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The echoed command after its prompt (`prompt` is the gray part).
        case command(prompt: String)
        case output
        /// `(nil)`, drawn dimmer.
        case null
        /// `(error) …`, soft red.
        case error
        /// Keel's own words (an unknown command was sent, a stream started or stopped), muted.
        case notice
    }

    public var text: String
    public var kind: Kind
    /// The command and reply this line belongs to, for Copy Reply (FR-CO09); nil for notices between them.
    public var reply: Int?

    public init(_ text: String, kind: Kind, reply: Int? = nil) { self.text = text; self.kind = kind; self.reply = reply }
}

/// The console's scrollback (FR-CO09, FR-CO07): the newest 10,000 lines and at most 16 MiB of text; older lines go
/// first. Lines are numbered from the first ever appended, so a view can follow appends and drops incrementally.
public struct ConsoleBuffer: Sendable, Equatable {
    public static let lineLimit = 10_000
    public static let byteLimit = 16 << 20

    public private(set) var lines: [ConsoleLine] = []
    /// The number of the first line kept (lines dropped so far).
    public private(set) var firstIndex = 0
    private var bytes = 0
    private let lineLimit: Int, byteLimit: Int

    public init(lineLimit: Int = ConsoleBuffer.lineLimit, byteLimit: Int = ConsoleBuffer.byteLimit) {
        self.lineLimit = max(lineLimit, 1); self.byteLimit = max(byteLimit, 1)
    }

    /// One past the number of the last line.
    public var endIndex: Int { firstIndex + lines.count }

    public mutating func append(contentsOf newLines: some Sequence<ConsoleLine>) {
        for var line in newLines {
            // A single line over the byte limit keeps its start, so the bound holds whatever the server sent.
            if line.text.utf8.count > byteLimit { line.text = String(decoding: line.text.utf8.prefix(byteLimit), as: UTF8.self) }
            lines.append(line); bytes += line.text.utf8.count
        }
        var drop = max(lines.count - lineLimit, 0)
        var remaining = bytes - lines.prefix(drop).reduce(0) { $0 + $1.text.utf8.count }
        while remaining > byteLimit, drop < lines.count { remaining -= lines[drop].text.utf8.count; drop += 1 }
        guard drop > 0 else { return }
        lines.removeFirst(drop); firstIndex += drop; bytes = remaining
    }

    public mutating func append(_ line: ConsoleLine) { append(contentsOf: CollectionOfOne(line)) }

    /// ⌥⌘K / ⌃L: everything goes; numbering continues.
    public mutating func clear() { firstIndex = endIndex; lines = []; bytes = 0 }
}

/// What running a console line came to.
public enum ConsoleOutcome: Sendable, Equatable {
    /// Lines to print: the reply, or why nothing ran.
    case printed([ConsoleLine])
    /// The policy wants a yes first (FR-SF03, FR-CO06): typed for FLUSHDB, FLUSHALL and multi-key DEL, plain for admin
    /// and KEYS. `warning` is the size warning measured first (FR-SF08). Run again with the confirmation to go on.
    case needsConfirmation(ConfirmationRequest, warning: ComplexityWarning?)
    /// An O(N) command on something large (FR-SF08): run again with a confirmation to send it anyway.
    case needsGoAhead(ComplexityWarning)
    /// MONITOR / SUBSCRIBE started; its lines arrive through `drainStream()` until `stopStream()`.
    case streaming([ConsoleLine])
}

/// Lines a stream produced since the last drain, and whether it has ended.
public struct ConsoleStreamDrain: Sendable, Equatable {
    public var lines: [ConsoleLine]
    /// Lines that arrived while the reader was behind and were dropped (only the newest 10,000 are kept).
    public var dropped: Int
    public var ended: Bool
}

/// One console (FR-CO01): its own connection, database and prompt, every command through the data path and the safety
/// policy (FR-CO06), replies printed like redis-cli (FR-CO03), streaming commands on a dedicated connection with Stop
/// (FR-CO07). Display only: nothing it prints is logged or written anywhere (FR-CO09).
public actor ConsoleSession {
    public nonisolated let id: UUID
    public let service: DataCommandService
    public nonisolated let profile: SafetyProfile
    /// `127.0.0.1:6379`, the prompt's name.
    public nonisolated let address: String
    /// The database the console's connection is on; only the console's own `SELECT` / `RESET` changes it.
    public private(set) var database: Int
    public private(set) var isStreaming = false

    private var replies = 0
    /// Bumped by `cancel()`, so a command whose size read was in flight when Stop came isn't sent after it.
    private var cancels = 0
    private var stream: Task<Void, Never>?
    private var streamed: [ConsoleLine] = []
    private var dropped = 0
    private var streamEnded = false
    private let streamLimit: Int

    public init(id: UUID = UUID(), service: DataCommandService, profile: SafetyProfile, database: Int, address: String? = nil, streamLimit: Int = ConsoleBuffer.lineLimit) {
        self.id = id; self.service = service; self.profile = profile; self.database = database; self.streamLimit = max(streamLimit, 1)
        // A tunnel's address names the server it reaches, not the local forward; " via SSH" isn't part of a prompt.
        self.address = (address ?? profile.server ?? profile.name).replacingOccurrences(of: " via SSH", with: "")
    }

    /// redis-cli's prompt: `127.0.0.1:6379> ` on db0, `127.0.0.1:6379[3]> ` elsewhere.
    public var prompt: String { Self.prompt(address: address, database: database) }

    public nonisolated static func prompt(address: String, database: Int) -> String { database == 0 ? "\(address)> " : "\(address)[\(database)]> " }

    /// Runs one line's arguments. `confirmation` is the user's yes to an earlier `needsConfirmation` or `needsGoAhead`
    /// for exactly these arguments; without it, a command that needs one sends nothing (the size reads of FR-SF08 aside).
    public func run(_ arguments: [Data], confirmation: CommandConfirmation? = nil) async -> ConsoleOutcome {
        guard !arguments.isEmpty, !isStreaming else { return .printed([]) }
        replies += 1
        let reply = replies, cancelsAtStart = cancels
        let context = DataContext(profile: profile, database: database, consoleID: id, confirmation: confirmation)
        let command = DataCommand.raw(arguments)
        switch await service.verdict(command, origin: .console, context: context) {
        case .readOnly, .blocked:
            // `execute` refuses it the same way, sending nothing; it gives the printed error.
            break
        case .confirmationRequired(let request):
            // KEYS and FLUSHALL show their size in the same sheet (FR-SF08); other confirmations measure nothing.
            let measures = request.operation == .keys || request.operation == .flushAll
            let warning = measures ? await ComplexityWarning.check(arguments, service: service, context: context) : nil
            guard cancels == cancelsAtStart else { return .printed([ConsoleLine("Not sent.", kind: .notice, reply: reply)]) }
            return .needsConfirmation(request, warning: warning)
        case .allow(let safetyClass):
            if confirmation == nil, let warning = await ComplexityWarning.check(arguments, service: service, context: context) { return .needsGoAhead(warning) }
            // Stop during the size read fails that read; the command itself must not go out after it.
            guard cancels == cancelsAtStart else { return .printed([ConsoleLine("Not sent.", kind: .notice, reply: reply)]) }
            if safetyClass == .streaming { return await startStream(command, context: context, reply: reply) }
        }
        do throws(DataCommandError) {
            let result = try await service.execute(command, origin: .console, context: context)
            if result.safetyClass == .session { moved(arguments, reply: result.reply) }
            var lines = Self.lines(RedisCliFormatter.format(result.reply), reply: reply)
            if result.isUnknownCommand { lines.insert(ConsoleLine("Keel doesn't know this command; it was sent as typed.", kind: .notice, reply: reply), at: 0) }
            return .printed(lines)
        } catch {
            var lines = [ConsoleLine(Self.errorText(error), kind: .error, reply: reply)]
            // A refused EXEC leaves the transaction open on the server; the user has to know how to end it.
            if case .refused(.readOnly(let message)) = error, String(decoding: arguments[0], as: UTF8.self).lowercased() == "exec" {
                lines.append(ConsoleLine(message, kind: .notice, reply: reply))
            }
            return .printed(lines)
        }
    }

    /// Follows the console's own `SELECT n` / `RESET` once the server said OK; a queued one (`MULTI`) changes nothing yet.
    private func moved(_ arguments: [Data], reply: RESPValue) {
        guard case .simpleString(let text) = reply else { return }
        let name = String(decoding: arguments[0], as: UTF8.self).lowercased()
        if name == "select", text == Data("OK".utf8), arguments.count == 2, let target = Int(String(decoding: arguments[1], as: UTF8.self)) { database = target }
        if name == "reset", text == Data("RESET".utf8) { database = 0 }
    }

    // MARK: - Streaming

    private func startStream(_ command: DataCommand, context: DataContext, reply: Int) async -> ConsoleOutcome {
        let values: AsyncStream<RESPValue>
        do throws(DataCommandError) { values = try await service.stream(command, context: context) } catch {
            return .printed([ConsoleLine(Self.errorText(error), kind: .error, reply: reply)])
        }
        isStreaming = true; streamed = []; dropped = 0; streamEnded = false
        stream = Task { [weak self, service, id] in
            var first = true
            for await value in values {
                await self?.received(value, reply: reply)
                // The server refused the command itself (`NOPERM`): nothing follows, so the stream ends without Stop.
                if first, case .error = value { await service.stopStream(console: id) }
                first = false
            }
            await self?.ended()
        }
        return .streaming([ConsoleLine("Reading messages… (Stop with ⌘.)", kind: .notice, reply: reply)])
    }

    private func received(_ value: RESPValue, reply: Int) {
        streamed += Self.lines(RedisCliFormatter.format(value), reply: reply)
        // Only the newest lines are kept while the console hasn't drained them (FR-CO07).
        if streamed.count > streamLimit {
            let excess = streamed.count - streamLimit
            streamed.removeFirst(excess); dropped += excess
        }
    }

    private func ended() { streamEnded = true; isStreaming = false; stream = nil }

    /// The stream's lines since the last call. Once `ended` is true the console takes commands again.
    public func drainStream() -> ConsoleStreamDrain {
        defer { streamed = []; dropped = 0 }
        return ConsoleStreamDrain(lines: streamed, dropped: dropped, ended: streamEnded && !isStreaming)
    }

    /// Stop (⌘.): closes the stream connection and returns once the stream has ended.
    public func stopStream() async {
        guard let stream else { return }
        await service.stopStream(console: id)
        await stream.value
    }

    /// Cancels a blocking command (FR-CO07) by closing the console's connection; the command in flight fails and the next
    /// one reconnects on this console's database.
    public func cancel() async {
        cancels += 1
        await service.closeConsole(id)
    }

    /// The tab closed or disconnected: the stream and the console's connection go.
    public func close() async {
        await stopStream()
        await service.closeConsole(id)
    }

    // MARK: - Text

    /// Formatted reply text as lines; `(nil)` and `(error) …` lines get their colors.
    static func lines(_ text: String, reply: Int) -> [ConsoleLine] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts.map { part in
            let kind: ConsoleLine.Kind = part == "(nil)" ? .null : part.hasPrefix("(error) ") ? .error : .output
            return ConsoleLine(part, kind: kind, reply: reply)
        }
    }

    /// Keel's own refusals and failures, as redis-cli prints errors: `(error) KEEL_READ_ONLY …` (FR-CO06).
    public static func errorText(_ error: DataCommandError) -> String {
        let message: String
        switch error {
        case .refused(.readOnly): message = "write commands are blocked on this connection"
        case .refused(.blocked(let text)): message = text
        case .refused(.confirmationRequired(let request)): message = request.message
        case .refused(.allow): message = ""
        case .invalidRequest(let text): message = text
        case .connection(let failure): message = failure.message
        case .command(let failure): message = commandMessage(failure)
        case .conflict: message = "the key changed meanwhile"
        }
        return "(error) KEEL_\(error.code) \(message)"
    }

    private static func commandMessage(_ error: RedisError) -> String {
        switch error {
        case .outcomeUnknown: return "the connection ended before the reply; the command may or may not have run"
        case .cancelled: return "cancelled"
        case .timeout: return "no reply in time; the connection was closed"
        case .notConnected: return "not connected; run the command again to reconnect"
        case .connectionFailed, .connectionLost: return "the connection was lost; run the command again to reconnect"
        case .codec, .unexpectedReply: return "the server sent a reply Keel can't read; the connection was closed"
        }
    }
}

import Darwin
import Foundation

/// Wire contract between the app's askpass broker and the `keel-askpass` helper (02 Architecture → Connections).
/// One request per connection: the header line `<nonce> <kind> <byte count>\n`, then ssh's prompt text (KEEL-010).
/// One reply: `P` + answer bytes, `D` (declined: fail the prompt) or `I` (not answered here: ask on the terminal).
public enum AskpassProtocol {
    /// Not `KEEL_`-prefixed: that prefix is reserved for Keel's own configuration.
    public static let socketVariable = "SSH_ASKPASS_KEEL_SOCKET"
    public static let nonceVariable = "SSH_ASKPASS_KEEL_NONCE"
    public static let helperName = "keel-askpass"
    /// The header line, newline included.
    public static let requestLimit = 128
    /// ssh's prompt text; a host-key prompt is a few hundred bytes, a longer one is cut here.
    public static let promptLimit = 4096
    public static let replyLimit = 4096
    public static let password: UInt8 = 0x50  // "P"
    public static let interactive: UInt8 = 0x49  // "I"
    public static let declined: UInt8 = 0x44  // "D"

    public struct Header: Equatable, Sendable {
        public var nonce: String
        public var kind: AskpassPrompt
        public var length: Int
        public init(nonce: String, kind: AskpassPrompt, length: Int) { self.nonce = nonce; self.kind = kind; self.length = length }
    }

    public static func request(nonce: String, kind: AskpassPrompt = .password, prompt: String = "") -> Data {
        let text = Data(prompt.utf8.prefix(promptLimit))
        return Data("\(nonce) \(kind.code) \(text.count)\n".utf8) + text
    }

    /// Parses a complete header line; nil for anything malformed, so the broker answers nothing.
    public static func header(from line: Data) -> Header? {
        guard line.count <= requestLimit, line.last == 0x0A else { return nil }
        let fields = String(decoding: line.dropLast(), as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, isValidNonce(String(fields[0])), let kind = AskpassPrompt(code: fields[1]), let length = Int(fields[2]),
            String(length) == fields[2], (0...promptLimit).contains(length)
        else { return nil }
        return Header(nonce: String(fields[0]), kind: kind, length: length)
    }

    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 64 && nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum AskpassPrompt: Equatable, Sendable {
    /// The only kind ever answered from the Keychain.
    case password
    /// Host-key trust, key passphrases, one-time codes: always typed by the person.
    case typed(echo: Bool)
    /// `SSH_ASKPASS_PROMPT=confirm`, answered by exit status.
    case confirm
    /// `SSH_ASKPASS_PROMPT=none`: an informational notice, no answer.
    case notice

    public static func classify(_ prompt: String, kind: String?) -> AskpassPrompt {
        switch kind {
        case "confirm": return .confirm
        case "none": return .notice
        default: break
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("yes/no") { return .typed(echo: true) }
        // "user@host's password:" and keyboard-interactive "Password:"; never a new-password or passphrase prompt.
        if text.hasSuffix("password:"), !text.contains("new password"), !text.contains("passphrase") { return .password }
        return .typed(echo: false)
    }

    /// One letter on the wire.
    var code: String {
        switch self {
        case .password: return "P"
        case .typed(let echo): return echo ? "E" : "H"
        case .confirm: return "C"
        case .notice: return "N"
        }
    }

    init?(code: Substring) {
        switch code {
        case "P": self = .password
        case "E": self = .typed(echo: true)
        case "H": self = .typed(echo: false)
        case "C": self = .confirm
        case "N": self = .notice
        default: return nil
        }
    }
}

/// The helper ssh runs as `SSH_ASKPASS`. Every prompt goes to the broker first: it answers a password prompt once from
/// the Keychain and relays every other prompt to the person in a sheet (KEEL-010). A prompt the broker doesn't take
/// (`I`, or no broker) is asked on the controlling terminal; Keel's tunnels have none, so it fails closed.
public struct AskpassHelper {
    public var arguments: [String]
    public var environment: [String: String]
    /// Sends a request to the broker socket and returns its reply; nil on any failure.
    public var exchange: (String, Data) -> Data? = AskpassHelper.exchange
    public var terminal: AskpassTerminal = DeviceTerminal()
    public var write: (Data) -> Void = { data in FileHandle.standardOutput.write(data) }

    public init(arguments: [String], environment: [String: String]) { self.arguments = arguments; self.environment = environment }

    public func run() -> Int32 {
        let prompt = arguments.count > 1 ? arguments[1] : ""
        let kind = AskpassPrompt.classify(prompt, kind: environment["SSH_ASKPASS_PROMPT"])
        if var reply = broker(prompt, kind: kind) {
            defer { reply.resetBytes(in: 0..<reply.count) }
            switch reply.first {
            case AskpassProtocol.password:
                // ssh reads a confirm answer from the exit status only.
                if kind == .confirm { return reply.dropFirst() == Data("yes".utf8) ? 0 : 1 }
                if kind == .notice { return 0 }
                write(reply.dropFirst() + Data([0x0A]))
                return 0
            case AskpassProtocol.declined:
                return kind == .notice ? 0 : 1
            default:
                break  // `I`: not answered by the broker, ask on the terminal below.
            }
        }
        switch kind {
        case .notice:
            terminal.show(prompt)
            return 0
        case .confirm:
            guard let answer = terminal.ask(prompt + " (yes/no) ", echo: true) else { return 1 }
            return answer.trimmingCharacters(in: .whitespaces).lowercased() == "yes" ? 0 : 1
        case .password:
            return typed(prompt, echo: false)
        case .typed(let echo):
            return typed(prompt, echo: echo)
        }
    }

    /// The broker's reply, or nil without broker variables or on any failure.
    private func broker(_ prompt: String, kind: AskpassPrompt) -> Data? {
        guard let socket = environment[AskpassProtocol.socketVariable], let nonce = environment[AskpassProtocol.nonceVariable],
            AskpassProtocol.isValidNonce(nonce)
        else { return nil }
        return exchange(socket, AskpassProtocol.request(nonce: nonce, kind: kind, prompt: prompt))
    }

    private func typed(_ prompt: String, echo: Bool) -> Int32 {
        guard let answer = terminal.ask(prompt, echo: echo) else { return 1 }
        write(Data((answer + "\n").utf8))
        return 0
    }

    public static func exchange(_ path: String, _ request: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)  // Touch ID or a relayed prompt (at most 90 s) may be on screen meanwhile.
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        while reply.count <= AskpassProtocol.replyLimit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return reply.isEmpty ? nil : reply }
            reply.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}

public protocol AskpassTerminal {
    func show(_ text: String)
    /// Nil when there is no terminal or input ended.
    func ask(_ prompt: String, echo: Bool) -> String?
}

/// The controlling terminal of the ssh that ran the helper, if it has one.
public struct DeviceTerminal: AskpassTerminal {
    public init() {}

    public func show(_ text: String) {
        let fd = open("/dev/tty", O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        put(fd, text + "\r\n")
    }

    public func ask(_ prompt: String, echo: Bool) -> String? {
        let fd = open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var saved = termios()
        let restore = !echo && tcgetattr(fd, &saved) == 0
        if restore {
            var silent = saved
            silent.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(fd, TCSAFLUSH, &silent)
        }
        defer { if restore { tcsetattr(fd, TCSAFLUSH, &saved); put(fd, "\r\n") } }
        put(fd, prompt)
        var line = [UInt8]()
        var byte: UInt8 = 0
        while line.count < 4096 {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
            if byte == 0x0A || byte == 0x0D { break }
            line.append(byte)
        }
        defer { line.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return String(decoding: line, as: UTF8.self)
    }

    private func put(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}

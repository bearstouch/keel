import Foundation
import KeelAskpass

/// One ssh question shown to the person (FR-CN07). The text is ssh's own, cut to 4 KiB, with terminal escapes and
/// control characters other than line breaks and tabs removed: a keyboard-interactive prompt comes from the server.
public struct SSHPrompt: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Unknown or changed host key: Accept answers ssh's `yes`, Reject declines. Keel never decides.
        case hostKey
        /// A password prompt the saved password didn't answer (none saved, or already used once).
        case password
        case passphrase
        /// One-time code, verification code and any other keyboard-interactive question.
        case code
        /// `SSH_ASKPASS_PROMPT=confirm` (e.g. an agent key confirmation): Allow / Deny.
        case confirm
        /// `SSH_ASKPASS_PROMPT=none`: shown until ssh moves on, never answered.
        case notice
    }

    public let id: UUID
    /// The tunnel's SSH destination, for the sheet's title.
    public let destination: String
    public let text: String
    public let kind: Kind
    /// Whether typed text may be shown while typing (ssh asked with echo on).
    public let echo: Bool
    /// The tunnel launch that asked; its prompts are withdrawn together when it ends.
    let owner: UUID

    init(id: UUID = UUID(), owner: UUID, destination: String, text: String, askpass: AskpassPrompt) {
        self.id = id; self.owner = owner; self.destination = destination
        self.text = Self.displayText(text)
        (kind, echo) = Self.classify(self.text, askpass: askpass)
    }

    /// Host key first: its text also says "fingerprint" and ends in a question, and must never be mistaken for a
    /// password. `askpass` is the helper's classification, which already decided password vs everything else.
    static func classify(_ text: String, askpass: AskpassPrompt) -> (Kind, Bool) {
        let lower = text.lowercased()
        switch askpass {
        case .confirm: return (.confirm, false)
        case .notice: return (.notice, false)
        case .password: return (.password, false)
        case .typed(let echo):
            if lower.contains("yes/no") || lower.contains("authenticity of host") || lower.contains("host key") { return (.hostKey, true) }
            if lower.contains("passphrase") { return (.passphrase, false) }
            if lower.contains("password") { return (.password, false) }
            return (.code, echo)
        }
    }

    static func displayText(_ text: String) -> String {
        var cleaned = ""
        var scalars = String(decoding: Data(text.utf8.prefix(AskpassProtocol.promptLimit)), as: UTF8.self).unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                // CSI and OSC sequences are dropped whole, like ssh's stderr line (TunnelExit).
                guard let next = scalars.next() else { break }
                if next == "[" { while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {} }
                if next == "]" { while let byte = scalars.next(), byte != "\u{7}", byte != "\u{1B}" {} }
                continue
            }
            if scalar == "\n" || scalar == "\t" { cleaned.unicodeScalars.append(scalar); continue }
            if scalar == "\r" { continue }
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || scalar.value == 0x7F { continue }
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The person's answer. Typed text is bytes so the caller can zero its copy.
public enum SSHPromptResponse: Equatable, Sendable {
    case text(Data)
    /// Host key or confirm: Accept / Allow.
    case accept
    /// Reject, Deny or Cancel.
    case decline
    /// Nobody answered within the relay's timeout, or the tunnel ended first.
    case cancelled
}

/// What the UI is told: show a prompt, or take one away (answered elsewhere, timed out, or its tunnel ended).
public enum SSHPromptEvent: Equatable, Sendable {
    case show(SSHPrompt)
    case withdraw(UUID)
}

/// Carries ssh's questions from the askpass broker to the sheet and the person's answers back (FR-CN07, KEEL-010).
/// Without a presenter, or after `timeout`, a prompt is cancelled, which fails it: Keel never answers on its own.
public actor PromptRelay {
    public static let defaultTimeout: Duration = .seconds(90)

    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var presenter: (@Sendable (SSHPromptEvent) -> Void)?
    private var waiting: [UUID: (owner: UUID, timer: Task<Void, Never>, continuation: CheckedContinuation<SSHPromptResponse, Never>)] = [:]
    private var notices: [UUID: UUID] = [:]
    /// Launches whose prompts were withdrawn. The broker withdraws from a detached task, so a prompt of the same launch
    /// can arrive afterwards; it is cancelled instead of staying on screen for a dead tunnel. 16 bytes per ssh launch.
    private var withdrawn: Set<UUID> = []

    /// `timeout` stays below the helper's 120 s receive timeout, so the helper always hears the outcome.
    public init(timeout: Duration = PromptRelay.defaultTimeout, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.suspendingSleep(for: $0) }) {
        self.timeout = timeout; self.sleep = sleep
    }

    /// The UI attaches here; events are delivered on the caller's executor, so the presenter hops to the main actor.
    public func setPresenter(_ presenter: (@Sendable (SSHPromptEvent) -> Void)?) { self.presenter = presenter }

    /// Shows `prompt` and waits for the answer. A notice returns `.cancelled` at once and stays up until withdrawn.
    public func ask(_ prompt: SSHPrompt) async -> SSHPromptResponse {
        guard let presenter, !withdrawn.contains(prompt.owner) else { return .cancelled }
        if prompt.kind == .notice {
            notices[prompt.id] = prompt.owner
            presenter(.show(prompt))
            return .cancelled
        }
        let timeout = timeout, sleep = sleep
        // The timer can only run `finish` after this actor call suspends, i.e. once the prompt is registered.
        let timer = Task { [weak self] in
            guard (try? await sleep(timeout)) != nil else { return }
            await self?.finish(prompt.id, .cancelled)
        }
        return await withCheckedContinuation { continuation in
            waiting[prompt.id] = (prompt.owner, timer, continuation)
            presenter(.show(prompt))
        }
    }

    /// The person answered. An unknown or already finished prompt is ignored, so a late click can't answer anything.
    public func respond(to id: UUID, with response: SSHPromptResponse) {
        if notices.removeValue(forKey: id) != nil { presenter?(.withdraw(id)); return }
        finish(id, response)
    }

    /// Cancels and withdraws every prompt of one tunnel launch (it became ready, failed or was stopped).
    func withdraw(owner: UUID) {
        withdrawn.insert(owner)
        for (id, entry) in waiting where entry.owner == owner { finish(id, .cancelled) }
        for (id, noticeOwner) in notices where noticeOwner == owner {
            notices[id] = nil; presenter?(.withdraw(id))
        }
    }

    var pendingCount: Int { waiting.count }

    private func finish(_ id: UUID, _ response: SSHPromptResponse) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        presenter?(.withdraw(id))
        entry.continuation.resume(returning: response)
    }
}

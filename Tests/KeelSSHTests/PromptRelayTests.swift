import KeelAskpass
import XCTest
@testable import KeelSSH

/// Records what the sheet would show and answers each prompt with `answer` (nil: never answers).
final class PromptScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [SSHPromptEvent] = []
    var answer: (@Sendable (SSHPrompt) -> SSHPromptResponse?)?

    init(answer: (@Sendable (SSHPrompt) -> SSHPromptResponse?)? = nil) { self.answer = answer }

    func attach(to relay: PromptRelay) async {
        await relay.setPresenter { [self] event in
            lock.withLock { log.append(event) }
            if case .show(let prompt) = event, let response = answer?(prompt) { Task { await relay.respond(to: prompt.id, with: response) } }
        }
    }

    var events: [SSHPromptEvent] { lock.withLock { log } }
    var shown: [SSHPrompt] {
        events.compactMap {
            if case .show(let prompt) = $0 { return prompt }
            return nil
        }
    }
}

final class PromptRelayTests: XCTestCase {
    static let hostKeyText = """
        The authenticity of host 'bastion (10.0.0.5)' can't be established.
        ED25519 key fingerprint is SHA256:Wb4qk3JzT1x0bD3gq1n9kQ0v2xYfG7Rj8pL5sM6tA1c.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """

    private func prompt(_ text: String, _ kind: AskpassPrompt, owner: UUID = UUID()) -> SSHPrompt {
        SSHPrompt(owner: owner, destination: "bastion", text: text, askpass: kind)
    }

    func testNonPasswordPromptsReachUI() async throws {
        // Classification: only ssh's password prompt is ever a candidate for the saved password.
        for (text, expected) in [
            (Self.hostKeyText, SSHPrompt.Kind.hostKey),
            (
                "Warning: the ED25519 host key for 'bastion' differs from the key for the IP address '10.0.0.5'\nOffending key for IP in /Users/me/.ssh/known_hosts:3\nAre you sure you want to continue connecting (yes/no)? ",
                .hostKey
            ),
            ("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", .passphrase),
            ("Verification code: ", .code),
            ("(deploy@bastion) One-time password (OATH) for `deploy': ", .password),
            ("New password: ", .password)
        ] {
            let kind = AskpassPrompt.classify(text, kind: nil)
            XCTAssertNotEqual(kind, .password, text)
            XCTAssertEqual(prompt(text, kind).kind, expected, text)
        }
        XCTAssertEqual(prompt("Confirm user presence for key ED25519", AskpassPrompt.classify("x", kind: "none")).kind, .notice)
        XCTAssertEqual(prompt("Allow use of key id_ed25519?", .confirm).kind, .confirm)

        // Through the broker: with a saved password registered, the host key still goes to the person, verbatim.
        let relay = PromptRelay()
        let screen = PromptScreen { $0.kind == .hostKey ? .accept : .decline }
        await screen.attach(to: relay)
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: relay)
        broker.peerProcess = { _ in ("/fixture/keel-askpass", 4242) }
        defer { broker.stop() }
        let reads = LockedCount()
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 }, destination: "bastion",
                password: {
                    reads.add(); return Data("secret".utf8)
                }))
        let hostKey = AskpassHelper.exchange(
            registration.socketPath, AskpassProtocol.request(nonce: registration.nonce, kind: .typed(echo: true), prompt: Self.hostKeyText))
        XCTAssertEqual(hostKey, Data([AskpassProtocol.password]) + Data("yes".utf8), "Accept types ssh's own `yes`")
        let passphrase = AskpassHelper.exchange(
            registration.socketPath, AskpassProtocol.request(nonce: registration.nonce, kind: .typed(echo: false), prompt: "Enter passphrase for key 'k': "))
        XCTAssertEqual(passphrase, Data([AskpassProtocol.declined]))
        XCTAssertEqual(screen.shown.map(\.kind), [.hostKey, .passphrase])
        XCTAssertEqual(screen.shown.first?.text, Self.hostKeyText, "ssh's exact text, line breaks kept")
        XCTAssertEqual(screen.shown.first?.destination, "bastion")
        XCTAssertEqual(reads.value, 0, "Non-password prompts never read the saved password")
        XCTAssertFalse(registration.activity.hostKeyDeclined)
    }

    func testTimeoutCancelsPrompt() async {
        let relay = PromptRelay(timeout: .milliseconds(50))
        let screen = PromptScreen()  // nobody answers
        await screen.attach(to: relay)
        let question = prompt(Self.hostKeyText, .typed(echo: true))
        let response = await relay.ask(question)
        XCTAssertEqual(response, .cancelled)
        XCTAssertEqual(screen.events, [.show(question), .withdraw(question.id)], "The sheet is taken away")
        await relay.respond(to: question.id, with: .accept)
        let pending = await relay.pendingCount
        XCTAssertEqual(pending, 0, "A late click answers nothing")
        XCTAssertEqual(screen.events.count, 2)
    }

    func testWithoutPresenterPromptsFailClosed() async {
        let relay = PromptRelay()
        let response = await relay.ask(prompt(Self.hostKeyText, .typed(echo: true)))
        XCTAssertEqual(response, .cancelled)
    }

    func testWithdrawingOwnerCancelsItsPromptsOnly() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen()
        await screen.attach(to: relay)
        let owner = UUID()
        let mine = prompt("Verification code: ", .typed(echo: false), owner: owner), other = prompt("Verification code: ", .typed(echo: false))
        async let first = relay.ask(mine)
        async let second = relay.ask(other)
        while await relay.pendingCount < 2 { await Task.yield() }
        await relay.withdraw(owner: owner)
        let firstResponse = await first
        XCTAssertEqual(firstResponse, .cancelled)
        await relay.respond(to: other.id, with: .text(Data("123456".utf8)))
        let secondResponse = await second
        XCTAssertEqual(secondResponse, .text(Data("123456".utf8)))
    }

    func testNoticeIsShownWithoutWaitingAndWithdrawnWithItsTunnel() async {
        let relay = PromptRelay()
        let screen = PromptScreen()
        await screen.attach(to: relay)
        let owner = UUID()
        let notice = prompt("Confirm user presence for key ED25519 SHA256:abc", .notice, owner: owner)
        let response = await relay.ask(notice)
        XCTAssertEqual(response, .cancelled)
        await relay.withdraw(owner: owner)
        XCTAssertEqual(screen.events, [.show(notice), .withdraw(notice.id)])
    }

    func testPromptTextLosesTerminalEscapesButKeepsLines() {
        let shown = prompt("\u{1B}]0;evil title\u{7}\u{1B}[31mRed\u{1B}[0m line\r\nsecond\u{202E}line\u{0}", .typed(echo: false))
        XCTAssertEqual(shown.text, "Red line\nsecondline")
        let long = prompt(String(repeating: "x", count: 10_000), .typed(echo: false))
        XCTAssertEqual(long.text.utf8.count, AskpassProtocol.promptLimit)
    }
}

final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

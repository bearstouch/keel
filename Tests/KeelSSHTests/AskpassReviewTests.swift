import KeelAskpass
import XCTest
@testable import KeelSSH

/// Review-driven extras for KEEL-010.
final class AskpassReviewTests: XCTestCase {
    /// The broker withdraws from a detached task; a prompt of that launch arriving afterwards must not reach the sheet.
    func testPromptAfterWithdrawIsCancelledWithoutShowing() async {
        let relay = PromptRelay()
        let screen = PromptScreen()  // never answers
        await screen.attach(to: relay)
        let owner = UUID()
        await relay.withdraw(owner: owner)
        let response = await relay.ask(SSHPrompt(owner: owner, destination: "bastion", text: PromptRelayTests.hostKeyText, askpass: .typed(echo: true)))
        XCTAssertEqual(response, .cancelled)
        XCTAssertTrue(screen.events.isEmpty, "Nothing is shown for a launch that already ended")
        let pending = await relay.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// A server's keyboard-interactive text reaches askpass as `(user@host) <text>`, with echo, like ssh's host-key
    /// question. Text that imitates a host-key question stays a typed answer to the server, never Accept/Reject.
    func testServerTextImitatingHostKeyIsATypedPrompt() async throws {
        for text in [
            "(deploy@bastion) \(PromptRelayTests.hostKeyText)",
            "(deploy@bastion) Are you sure you want to continue connecting (yes/no)? ",
            "(deploy@bastion) Your host key expired. Renew it (yes/no)?",
            "(deploy@bastion) The authenticity of host 'bastion' can't be established.",
            "(deploy@bastion) Enter passphrase for key 'id_ed25519': "
        ] {
            let question = SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: AskpassPrompt.classify(text, kind: nil))
            XCTAssertEqual(question.kind, .code, text)
            XCTAssertTrue(question.fromServer, text)
        }
        // Without ssh's own question as the last line, even unprefixed text is not a host key.
        for text in ["Host key rotation pending (yes/no)?", "The authenticity of host 'bastion' can't be established."] {
            XCTAssertNotEqual(SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: .typed(echo: true)).kind, .hostKey, text)
        }
        // ssh's real questions, including the retry after a wrong answer and UpdateHostKeys=ask.
        for text in [PromptRelayTests.hostKeyText, "Please type 'yes', 'no' or the fingerprint: ", "Please type 'yes' or 'no': ", "Accept updated hostkeys? (yes/no): "] {
            let question = SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: AskpassPrompt.classify(text, kind: nil))
            XCTAssertEqual(question.kind, .hostKey, text)
            XCTAssertFalse(question.fromServer, text)
        }

        // Declining the server's question is not reported as a rejected host key.
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .decline }
        await screen.attach(to: relay)
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: relay)
        broker.peerProcess = { _ in ("/fixture/keel-askpass", 4242) }
        defer { broker.stop() }
        let registration = try XCTUnwrap(broker.register(parent: { 4242 }, password: nil))
        let spoof = "(deploy@bastion) \(PromptRelayTests.hostKeyText)"
        let reply = AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce, kind: .typed(echo: true), prompt: spoof))
        XCTAssertEqual(reply, Data([AskpassProtocol.declined]))
        XCTAssertEqual(screen.shown.map(\.kind), [.code])
        XCTAssertFalse(registration.activity.hostKeyDeclined)
    }

    /// Touch ID for the saved password counts as a prompt on screen, so the connect deadline doesn't run out meanwhile.
    func testSavedPasswordConfirmationCountsAsAsking() async throws {
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: PromptRelay())
        broker.peerProcess = { _ in ("/fixture/keel-askpass", 4242) }
        defer { broker.stop() }
        let gate = LockedFlag(), release = LockedFlag()
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    gate.set()
                    while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
                    return Data("secret".utf8)
                }))
        let path = registration.socketPath, request = AskpassProtocol.request(nonce: registration.nonce, kind: .password, prompt: "deploy@bastion's password: ")
        let reply = Task.detached { AskpassHelper.exchange(path, request) }
        while !gate.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(registration.activity.isAsking)
        release.set()
        let answer = await reply.value
        XCTAssertEqual(answer, Data([AskpassProtocol.password]) + Data("secret".utf8))
        XCTAssertFalse(registration.activity.isAsking)
        XCTAssertFalse(registration.activity.hostKeyDeclined)
    }
}

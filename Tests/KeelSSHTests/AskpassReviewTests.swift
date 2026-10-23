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

import Foundation
import KeelAskpass
import SwiftUI
import XCTest
@testable import KeelSSH
@testable import KeelUI

extension PromptRelay {
    /// What a tunnel's ssh would ask through the broker.
    fileprivate func askForTest(_ text: String) async -> SSHPromptResponse {
        await ask(SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: AskpassPrompt.classify(text, kind: nil)))
    }
}

final class SSHPromptSheetTests: XCTestCase {
    @MainActor private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out")
    }

    /// Prompts queue one at a time; an answer reaches the relay; a withdrawn prompt leaves the queue.
    @MainActor func testCenterQueuesAnswersAndWithdraws() async throws {
        let relay = PromptRelay(timeout: .seconds(30))
        let center = SSHPromptCenter(relay: relay)
        await center.attach()
        let first = Task.detached { await relay.askForTest("Are you sure you want to continue connecting (yes/no/[fingerprint])? ") }
        await waitFor { center.queue.count == 1 }
        let second = Task.detached { await relay.askForTest("Verification code: ") }
        await waitFor { center.queue.count == 2 }
        XCTAssertEqual(center.current?.kind, .hostKey, "The first prompt stays on screen")
        center.respond(to: try XCTUnwrap(center.current).id, with: .accept)
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse, .accept)
        XCTAssertEqual(center.current?.kind, .code)
        center.respond(to: try XCTUnwrap(center.current).id, with: .text(Data("123456".utf8)))
        let secondResponse = await second.value
        XCTAssertEqual(secondResponse, .text(Data("123456".utf8)))
        XCTAssertNil(center.current)
    }

    /// The prompt on screen is withdrawn (its tunnel went away) while another bastion's host key waits: a late click on
    /// the outgoing sheet must not answer the next prompt, which the user never saw.
    @MainActor func testAnswerForAWithdrawnPromptNeverAnswersTheNextOne() async throws {
        let relay = PromptRelay(timeout: .seconds(30))
        let center = SSHPromptCenter(relay: relay)
        await center.attach()
        let passphrase = "Enter passphrase for key 'k': ", hostKey = "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
        let shown = SSHPrompt(owner: UUID(), destination: "bastion1", text: passphrase, askpass: AskpassPrompt.classify(passphrase, kind: nil))
        let next = SSHPrompt(owner: UUID(), destination: "bastion2", text: hostKey, askpass: AskpassPrompt.classify(hostKey, kind: nil))
        let first = Task.detached { await relay.ask(shown) }
        await waitFor { center.queue.count == 1 }
        let second = Task.detached { await relay.ask(next) }
        await waitFor { center.queue.count == 2 }
        XCTAssertEqual(center.current?.id, shown.id)

        await relay.withdraw(owner: shown.owner)
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse, .cancelled)
        await waitFor { center.queue.count == 1 }
        center.respond(to: shown.id, with: .accept)
        center.respond(to: UUID(), with: .accept)
        XCTAssertEqual(center.queue.map(\.id), [next.id], "the queued host key still waits for its own answer")

        center.respond(to: next.id, with: .decline)
        let secondResponse = await second.value
        XCTAssertEqual(secondResponse, .decline, "bastion2's ssh gets only the answer given on its own sheet")
        XCTAssertNil(center.current)
    }

    @MainActor func testTimedOutPromptLeavesTheSheet() async {
        let relay = PromptRelay(timeout: .milliseconds(50))
        let center = SSHPromptCenter(relay: relay)
        await center.attach()
        let response = await relay.askForTest("Enter passphrase for key 'k': ")
        XCTAssertEqual(response, .cancelled)
        await waitFor { center.queue.isEmpty }
    }

    @MainActor func testSheetWordingAndFields() {
        XCTAssertEqual(SSHPromptSheet.title(.hostKey), "Verify the SSH host key")
        XCTAssertFalse(SSHPromptSheet.takesText(.hostKey), "A host key is accepted or rejected, never typed")
        XCTAssertTrue(SSHPromptSheet.takesText(.passphrase))
        XCTAssertEqual(SSHPromptSheet.fieldLabel(.code), "Answer")
        let text = "(deploy@bastion) Verification code: "
        let server = SSHPrompt(owner: UUID(), destination: "bastion", text: text, askpass: AskpassPrompt.classify(text, kind: nil))
        XCTAssertEqual(SSHPromptSheet.subtitle(SSHPrompt(owner: UUID(), destination: "bastion", text: "Verification code: ", askpass: .typed(echo: false))), "ssh to bastion")
        XCTAssertEqual(SSHPromptSheet.subtitle(server), "Asked by the SSH server bastion", "A server's text is never presented as ssh's own")
        _ = RootView(prompts: SSHPromptCenter(relay: PromptRelay())).body  // Building the body must not trap.
    }
}

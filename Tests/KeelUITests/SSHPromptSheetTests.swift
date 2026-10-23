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
        center.respond(.accept)
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse, .accept)
        XCTAssertEqual(center.current?.kind, .code)
        center.respond(.text(Data("123456".utf8)))
        let secondResponse = await second.value
        XCTAssertEqual(secondResponse, .text(Data("123456".utf8)))
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
        _ = RootView(prompts: SSHPromptCenter(relay: PromptRelay())).body  // Building the body must not trap.
    }
}

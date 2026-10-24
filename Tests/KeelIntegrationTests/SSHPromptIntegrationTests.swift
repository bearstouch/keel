import Darwin
import Foundation
import KeelCore
import KeelSSH
import XCTest

/// KEEL-010 through a real `/usr/bin/ssh`, the built `keel-askpass` and the broker's real peer checks. Same fixture as
/// `TunnelIntegrationTests` (KEEL-048's sshd container, or `Tests/Fixtures/SSH/serve.sh`), with `-F <fixture>/prompt_config`: the fixture's host key
/// is unknown there, so ssh asks about it. The user's `~/.ssh` is never read or written.
final class SSHPromptIntegrationTests: XCTestCase {
    private var fixture = ""
    private var helper = ""
    private var sshPort = 22_422, redisPort: UInt16 = 26_399

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(IntegrationGate.isEnabled(environment), "set KEEL_INTEGRATION=1")
        fixture = try XCTUnwrap(environment["KEEL_INTEGRATION_SSH_FIXTURE"], "run scripts/integration-matrix.py, or start Tests/Fixtures/SSH/serve.sh and pass its folder")
        sshPort = Int(environment["KEEL_INTEGRATION_SSH_PORT"] ?? "") ?? sshPort
        redisPort = UInt16(environment["KEEL_INTEGRATION_SSH_REDIS_PORT"] ?? "") ?? redisPort
        helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(AskpassBroker.helperName).path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper), "Run `swift build` first to build \(AskpassBroker.helperName).")
        // Each test starts with the host key unknown.
        try Data().write(to: URL(fileURLWithPath: fixture + "/prompt_known_hosts"))
    }

    private struct PromptLauncher: TunnelProcessLauncher {
        let config: String
        func launch(executable: String, arguments: [String], environment: [String: String]) throws(TunnelError) -> any TunnelProcess {
            try SSHProcessLauncher().launch(executable: executable, arguments: ["-F", config] + arguments, environment: environment)
        }
    }

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [SSHPrompt] = []
        let response: SSHPromptResponse
        init(_ response: SSHPromptResponse) { self.response = response }
        func record(_ prompt: SSHPrompt) { lock.withLock { log.append(prompt) } }
        var prompts: [SSHPrompt] { lock.withLock { log } }
    }

    private func run(answering response: SSHPromptResponse) async throws -> (Result<TunnelLease, TunnelError>, [SSHPrompt], TunnelManager) {
        let relay = PromptRelay(timeout: .seconds(20))
        let answers = Answers(response)
        await relay.setPresenter { event in
            guard case .show(let prompt) = event else { return }
            answers.record(prompt)
            Task { await relay.respond(to: prompt.id, with: answers.response) }
        }
        let broker = AskpassBroker(helperPath: helper, relay: relay)
        addTeardownBlock { broker.stop() }
        let manager = TunnelManager(launcher: PromptLauncher(config: fixture + "/prompt_config"), askpass: broker)
        let configuration = SSHTunnelConfiguration(
            destination: "127.0.0.1", port: sshPort, identityFile: fixture + "/client_key", redisHost: "127.0.0.1", redisPort: redisPort)
        do {
            let lease = try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .seconds(10))
            return (.success(lease), answers.prompts, manager)
        } catch {
            return (.failure(error), answers.prompts, manager)
        }
    }

    /// AC2: the unknown host key is shown with ssh's text; Reject fails the connection with "Host key not accepted".
    func testRejectingUnknownHostKeyFailsTheConnection() async throws {
        let (result, prompts, manager) = try await run(answering: .decline)
        defer { Task { await manager.shutdown() } }
        XCTAssertEqual(prompts.map(\.kind), [.hostKey])
        let text = try XCTUnwrap(prompts.first?.text)
        XCTAssertTrue(text.contains("The authenticity of host '[127.0.0.1]:\(sshPort)"), text)
        XCTAssertTrue(text.contains("SHA256:"), "The fingerprint is shown: \(text)")
        guard case .failure(let error) = result else { return XCTFail("Connected without an accepted host key") }
        XCTAssertEqual(ConnectionFailure(tunnel: error, destination: "127.0.0.1").message, "Host key not accepted for 127.0.0.1.")
        let known = try String(contentsOfFile: fixture + "/prompt_known_hosts", encoding: .utf8)
        XCTAssertTrue(known.isEmpty, "Nothing was trusted")
    }

    func testAcceptingHostKeyOpensTheTunnel() async throws {
        let (result, prompts, manager) = try await run(answering: .accept)
        defer { Task { await manager.shutdown() } }
        XCTAssertEqual(prompts.map(\.kind), [.hostKey])
        guard case .success(let lease) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(RuntimeDirectory.isOwnedSocket(lease.socketPath))
        await manager.shutdown()
    }
}

import Darwin
import KeelAskpass
import XCTest
@testable import KeelSSH

/// The tunnel manager with a real askpass broker; the fake ssh asks its prompts through the broker socket, like
/// `keel-askpass` would.
final class TunnelAskpassTests: XCTestCase {
    private var runtime: RuntimeDirectory!
    private let launcher = FakeLauncher()
    private let configuration = SSHTunnelConfiguration(destination: "bastion", user: "deploy", redisHost: "127.0.0.1", redisPort: 6379)

    override func setUpWithError() throws {
        runtime = try RuntimeDirectory.create(name: "keel-test-\(RuntimeDirectory.randomID())", owner: nil)
    }

    override func tearDown() { runtime.remove(); runtime = nil }

    /// Every helper request looks like it came from the bundled helper, child of the most recently launched fake ssh.
    private func broker(_ relay: PromptRelay) -> AskpassBroker {
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: relay)
        let launcher = launcher
        broker.peerProcess = { _ in ("/fixture/keel-askpass", launcher.processes.last?.group.pid ?? -1) }
        return broker
    }

    private func manager(_ broker: AskpassBroker, probe: @escaping @Sendable (String) -> Bool) -> TunnelManager {
        let runtime = runtime!
        return TunnelManager(
            launcher: launcher, options: TunnelManager.Options(pollInterval: .milliseconds(10)), environment: ["HOME": "/Users/me", "SSH_ASKPASS": "/evil"], askpass: broker,
            makeRuntime: { runtime }, probe: probe, sleep: { try await Task.sleep(for: min($0, .milliseconds(10))) })
    }

    /// What the fake ssh's helper sends for `prompt`.
    private static func ask(_ process: FakeProcess, _ prompt: String, kind: AskpassPrompt) -> Data? {
        guard let socket = process.environment[AskpassProtocol.socketVariable], let nonce = process.environment[AskpassProtocol.nonceVariable] else { return nil }
        return AskpassHelper.exchange(socket, AskpassProtocol.request(nonce: nonce, kind: kind, prompt: prompt))
    }

    func testRejectedHostKeyFailsWithHostKeyNotAccepted() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { $0.kind == .hostKey ? .decline : nil }
        await screen.attach(to: relay)
        let broker = broker(relay)
        defer { broker.stop() }
        launcher.onLaunch = { process in
            Thread.detachNewThread {
                // ssh exits 255 after its askpass declines the host key.
                if Self.ask(process, PromptRelayTests.hostKeyText, kind: .typed(echo: true)) == Data([AskpassProtocol.declined]) {
                    process.finish(TunnelExit(status: .exited(255), lastErrorLine: "Host key verification failed."))
                }
            }
        }
        let manager = manager(broker, probe: { _ in false })
        do {
            _ = try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .seconds(5))
            XCTFail("Connected without an accepted host key")
        } catch {
            XCTAssertEqual(error, .hostKeyNotAccepted(TunnelExit(status: .exited(255), lastErrorLine: "Host key verification failed.")))
        }
        XCTAssertEqual(screen.shown.map(\.text), [PromptRelayTests.hostKeyText])
        XCTAssertEqual(broker.registeredCount, 0, "The launch's nonce ends with it")
    }

    func testConnectTimeoutWaitsWhileThePersonReadsAPrompt() async throws {
        let relay = PromptRelay()
        // Answered by hand below, long after the 100 ms connect timeout would have run out.
        let screen = PromptScreen()
        await screen.attach(to: relay)
        let broker = broker(relay)
        defer { broker.stop() }
        let accepted = LockedFlag()
        launcher.onLaunch = { process in
            Thread.detachNewThread {
                if Self.ask(process, PromptRelayTests.hostKeyText, kind: .typed(echo: true)) == Data([AskpassProtocol.password]) + Data("yes".utf8) { accepted.set() }
            }
        }
        let manager = manager(broker, probe: { _ in accepted.value })
        let configuration = configuration
        let acquiring = Task { try await manager.acquire(profileID: UUID(), configuration: configuration, connectTimeout: .milliseconds(100)) }
        while screen.shown.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(400))
        await relay.respond(to: screen.shown[0].id, with: .accept)
        let lease = try await acquiring.value
        XCTAssertFalse(lease.socketPath.isEmpty)
        let environment = try XCTUnwrap(launcher.processes.first?.environment)
        XCTAssertEqual(environment["SSH_ASKPASS"], "/fixture/keel-askpass", "Keel's helper replaces an inherited one")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertNotNil(environment[AskpassProtocol.nonceVariable])
        await manager.shutdown()
    }

    /// Closing the tab while ssh's host-key question is on screen stops ssh and takes the sheet away; nobody can
    /// accept a key for a tab that is gone.
    func testCancelledConnectWithdrawsThePendingHostKeyPrompt() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen()
        await screen.attach(to: relay)
        let broker = broker(relay)
        defer { broker.stop() }
        let answers = LockedList()
        launcher.onLaunch = { process in Thread.detachNewThread { answers.append(Self.ask(process, PromptRelayTests.hostKeyText, kind: .typed(echo: true))) } }
        let manager = manager(broker, probe: { _ in false })
        let configuration = configuration, profile = UUID()
        let acquiring = Task { try await manager.acquire(profileID: profile, configuration: configuration, connectTimeout: .seconds(5)) }
        while screen.shown.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        acquiring.cancel()
        if case .failure(let error) = await acquiring.result { XCTAssertEqual(error as? TunnelError, .cancelled) } else { XCTFail("Expected cancelled") }
        XCTAssertEqual(launcher.processes.first?.sentSignals, [SIGTERM])
        XCTAssertEqual(broker.registeredCount, 0, "The launch's nonce ends with it")
        let prompt = try XCTUnwrap(screen.shown.first)
        for _ in 0..<200 where !screen.events.contains(.withdraw(prompt.id)) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(screen.events.contains(.withdraw(prompt.id)), "The sheet goes away")
        let pending = await relay.pendingCount
        XCTAssertEqual(pending, 0)
        // A late click can't answer it any more: the helper never hears an accept.
        await relay.respond(to: prompt.id, with: .accept)
        for _ in 0..<200 where answers.values.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(answers.values.first ?? nil, Data([AskpassProtocol.password]) + Data("yes".utf8))
        let users = await manager.userCount(profileID: profile)
        XCTAssertEqual(users, 0)
    }

    func testSavedPasswordIsReadOncePerLaunch() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .decline }
        await screen.attach(to: relay)
        let broker = broker(relay)
        defer { broker.stop() }
        let reads = LockedCount(), replies = LockedList()
        launcher.onLaunch = { process in
            Thread.detachNewThread {
                replies.append(Self.ask(process, "deploy@bastion's password: ", kind: .password))
                replies.append(Self.ask(process, "deploy@bastion's password: ", kind: .password))
                process.finish(TunnelExit(status: .exited(255), lastErrorLine: "deploy@bastion: Permission denied (password)."))
            }
        }
        let manager = manager(broker, probe: { _ in false })
        do {
            _ = try await manager.acquire(
                profileID: UUID(), configuration: configuration, connectTimeout: .seconds(5),
                savedPassword: {
                    reads.add(); return Data("wrong".utf8)
                })
            XCTFail("Connected")
        } catch {
            guard case .exited = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(replies.values, [Data([AskpassProtocol.password]) + Data("wrong".utf8), Data([AskpassProtocol.declined])])
        XCTAssertEqual(screen.shown.map(\.kind), [.password], "The second password prompt is the person's")
    }

    func testHelperLocation() {
        let app = URL(fileURLWithPath: "/Applications/Keel.app/Contents/MacOS/Keel")
        XCTAssertEqual(AskpassHelperLocation.find(executable: app, isExecutable: { $0.hasSuffix("Contents/Helpers/keel-askpass") }), "/Applications/Keel.app/Contents/Helpers/keel-askpass")
        let build = URL(fileURLWithPath: "/src/keel/.build/debug/Keel")
        XCTAssertEqual(AskpassHelperLocation.find(executable: build, isExecutable: { $0 == "/src/keel/.build/debug/keel-askpass" }), "/src/keel/.build/debug/keel-askpass")
        XCTAssertNil(AskpassHelperLocation.find(executable: build, isExecutable: { _ in false }))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data?] = []
    func append(_ item: Data?) { lock.withLock { items.append(item) } }
    var values: [Data?] { lock.withLock { items } }
}

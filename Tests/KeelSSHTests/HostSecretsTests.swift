import Darwin
import KeelAskpass
import LocalAuthentication
import XCTest
@testable import KeelSSH

/// The saved password's binding to the host's connection revision (FR-CN06, KEEL-010 AC4).
final class HostSecretsTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)

    private func savedHost() async throws -> (HostLibrary, MemoryHostSecrets, SavedHost) {
        let secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: MemoryHostStorage(), secrets: secrets)
        let host = try await library.create(HostDraft(name: "Bastion", destination: "bastion", user: "deploy"))
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: false), expectedRevision: host.revision)
        return (library, secrets, saved)
    }

    func testDestinationChangeDeletesPassword() async throws {
        let (library, secrets, host) = try await savedHost()
        let lookup = try XCTUnwrap(library.savedPassword(for: host, gate: FixedGate(allow: true)))
        let before = await lookup()
        XCTAssertEqual(before, secret)
        let moved = try await library.update(id: host.id, HostDraft(name: "Bastion", destination: "bastion-2", user: "deploy"), expectedRevision: host.revision)
        XCTAssertNil(moved.savedPassword)
        XCTAssertNil(secrets[host.id], "The Keychain item is deleted")
        XCTAssertGreaterThan(moved.connectionRevision, host.connectionRevision)
        let after = await lookup()
        XCTAssertNil(after, "A tunnel started for the old destination gets nothing")
        XCTAssertNil(library.savedPassword(for: moved, gate: FixedGate(allow: true)), "Nothing to offer the new destination")
    }

    func testRenameKeepsPasswordAndLookup() async throws {
        let (library, _, host) = try await savedHost()
        let lookup = try XCTUnwrap(library.savedPassword(for: host, gate: FixedGate(allow: true)))
        _ = try await library.update(id: host.id, HostDraft(name: "Bastion (prod)", destination: "bastion", user: "deploy"), expectedRevision: host.revision)
        let value = await lookup()
        XCTAssertEqual(value, secret)
    }

    func testDeclinedConfirmationReadsNothing() async throws {
        let secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: MemoryHostStorage(), secrets: secrets)
        let host = try await library.create(HostDraft(name: "Bastion", destination: "bastion"))
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: true), expectedRevision: host.revision)
        let value = await library.savedPassword(for: saved, gate: FixedGate(allow: false))?()
        XCTAssertNil(value)
        XCTAssertEqual(secrets.reads, 0)
    }

    /// AC3: Touch ID declined (through an injected LAContext) leaves the Keychain unread, and ssh's password prompt
    /// goes to the person through the prompt relay instead.
    func testTouchIDDeclineFallsBack() async throws {
        let secrets = MemoryHostSecrets()
        let library = HostLibrary(storage: MemoryHostStorage(), secrets: secrets)
        let host = try await library.create(HostDraft(name: "Bastion", destination: "bastion", user: "deploy"))
        let saved = try await library.setPassword(id: host.id, .save(secret, requiresUserPresence: true), expectedRevision: host.revision)
        let context = DecliningContext()
        let lookup = try XCTUnwrap(library.savedPassword(for: saved, gate: LocalAuthenticationGate(makeContext: { context })))

        let relay = PromptRelay()
        let typed = Data("typed-by-person".utf8)
        let screen = PromptScreen { _ in .text(typed) }
        await screen.attach(to: relay)
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: relay)
        broker.peerProcess = { _ in ("/fixture/keel-askpass", 4242) }
        defer { broker.stop() }
        let registration = try XCTUnwrap(broker.register(parent: { 4242 }, destination: "bastion", password: lookup))
        let prompt = "deploy@bastion's password: "
        let answer = AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce, kind: .password, prompt: prompt))

        XCTAssertEqual(answer, Data([AskpassProtocol.password]) + typed, "The person's answer, not the saved password")
        XCTAssertEqual(screen.shown.map(\.kind), [.password])
        XCTAssertEqual(context.reasons.count, 1, "Touch ID was asked once")
        XCTAssertTrue(context.reasons[0].contains("Bastion"))
        XCTAssertEqual(secrets.reads, 0, "A declined check never reads the Keychain")
        XCTAssertEqual(secrets[saved.id], secret, "Declining doesn't remove the saved password")
    }

    func testTouchIDApprovalReadsThePasswordOnce() async throws {
        let (library, secrets, host) = try await savedHost()
        let required = try await library.setPassword(id: host.id, .policy(requiresUserPresence: true), expectedRevision: host.revision)
        let context = DecliningContext(allow: true)
        let value = await library.savedPassword(for: required, gate: LocalAuthenticationGate(makeContext: { context }))?()
        XCTAssertEqual(value, secret)
        XCTAssertEqual(context.reasons.count, 1)
        XCTAssertEqual(secrets.reads, 1)
    }
}

/// An `LAContext` stand-in: records each request, then approves or fails with `userCancel` like a declined Touch ID.
final class DecliningContext: UserPresenceContext, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let allow: Bool
    init(allow: Bool = false) { self.allow = allow }
    var reasons: [String] { lock.withLock { log } }
    func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        lock.withLock { log.append(localizedReason) }
        guard allow else { throw LAError(.userCancel) }
        return true
    }
}

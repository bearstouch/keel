import Darwin
import KeelAskpass
import XCTest
@testable import KeelSSH

final class AskpassBrokerTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)
    private let passwordPrompt = "deploy@bastion's password: "

    private func broker(peer: (path: String, parent: pid_t)?, relay: PromptRelay? = nil) -> AskpassBroker {
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass", relay: relay)
        broker.peerProcess = { _ in peer }
        return broker
    }

    private func ask(_ registration: AskpassBroker.Registration, nonce: String? = nil, _ text: String, kind: AskpassPrompt = .password) -> Data? {
        AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: nonce ?? registration.nonce, kind: kind, prompt: text))
    }

    func testAnswersPasswordOnce() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .text(Data("typed-by-person".utf8)) }
        await screen.attach(to: relay)
        let broker = broker(peer: ("/fixture/keel-askpass", 4242), relay: relay)
        defer { broker.stop() }
        let reads = LockedCount(), secret = secret
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 }, destination: "bastion",
                password: {
                    reads.add(); return secret
                }))
        XCTAssertEqual(ask(registration, passwordPrompt), Data([AskpassProtocol.password]) + secret)
        XCTAssertTrue(screen.shown.isEmpty, "The saved password answers without a sheet")
        // ssh asks again (wrong password, or a second factor): the person answers, the Keychain isn't read again.
        XCTAssertEqual(ask(registration, passwordPrompt), Data([AskpassProtocol.password]) + Data("typed-by-person".utf8))
        XCTAssertEqual(screen.shown.map(\.kind), [.password])
        XCTAssertEqual(screen.shown.first?.text, passwordPrompt.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(reads.value, 1)
    }

    func testPasswordGoesToThePersonWhenNoneIsSavedOrUseIsDenied() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .decline }
        await screen.attach(to: relay)
        let broker = broker(peer: ("/fixture/keel-askpass", 4242), relay: relay)
        defer { broker.stop() }
        let none = try XCTUnwrap(broker.register(parent: { 4242 }, password: nil))
        XCTAssertEqual(ask(none, passwordPrompt), Data([AskpassProtocol.declined]))
        let denied = try XCTUnwrap(broker.register(parent: { 4242 }, password: { nil }))  // Touch ID declined
        XCTAssertEqual(ask(denied, passwordPrompt), Data([AskpassProtocol.declined]))
        XCTAssertEqual(screen.shown.map(\.kind), [.password, .password])
    }

    func testRejectsForeignPeer() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .accept }
        await screen.attach(to: relay)
        let reads = LockedCount(), secret = secret
        // Another program, a helper whose parent isn't the ssh, a helper asked before ssh's pid is known.
        for (peer, parent) in [(("/elsewhere/tool", pid_t(4242)), pid_t?(4242)), (("/fixture/keel-askpass", 999), 4242), (("/fixture/keel-askpass", 4242), nil)] {
            let broker = broker(peer: peer, relay: relay)
            defer { broker.stop() }
            let registration = try XCTUnwrap(
                broker.register(
                    parent: { parent },
                    password: {
                        reads.add(); return secret
                    }))
            XCTAssertEqual(ask(registration, passwordPrompt), Data([AskpassProtocol.interactive]))
            XCTAssertEqual(broker.registeredCount, 0, "A refused request revokes the launch's nonce")
            broker.peerProcess = { _ in ("/fixture/keel-askpass", 4242) }
            XCTAssertEqual(ask(registration, PromptRelayTests.hostKeyText, kind: .typed(echo: true)), Data([AskpassProtocol.interactive]), "Nothing more for that nonce")
        }
        XCTAssertEqual(reads.value, 0)
        XCTAssertTrue(screen.shown.isEmpty, "A foreign helper never reaches the person")
    }

    func testNonceIsSingleUse() throws {
        let broker = broker(peer: ("/fixture/keel-askpass", 4242))
        defer { broker.stop() }
        let reads = LockedCount(), secret = secret
        let first = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    reads.add(); return secret
                }))
        XCTAssertEqual(ask(first, passwordPrompt), Data([AskpassProtocol.password]) + secret)
        XCTAssertEqual(ask(first, passwordPrompt), Data([AskpassProtocol.interactive]), "The password is released once per nonce")
        broker.unregister(first)
        XCTAssertEqual(ask(first, passwordPrompt), Data([AskpassProtocol.interactive]), "A finished launch's nonce answers nothing")
        let second = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    reads.add(); return secret
                }))
        XCTAssertNotEqual(second.nonce, first.nonce)
        XCTAssertEqual(ask(second, nonce: first.nonce, passwordPrompt), Data([AskpassProtocol.interactive]), "An old nonce can't be replayed against a new launch")
        XCTAssertEqual(ask(second, nonce: AskpassProtocol.makeNonce(), passwordPrompt), Data([AskpassProtocol.interactive]))
        XCTAssertEqual(reads.value, 1)
    }

    func testMalformedRequestsGetNothing() throws {
        let broker = broker(peer: ("/fixture/keel-askpass", 4242))
        defer { broker.stop() }
        let reads = LockedCount(), secret = secret
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    reads.add(); return secret
                }))
        for request in [
            Data("\(registration.nonce)\n".utf8),  // Trellis's bare nonce line
            Data("\(registration.nonce) P 10\nshort".utf8),  // fewer bytes than announced
            Data("\(registration.nonce) X 0\n".utf8), Data("\(registration.nonce) P 99999\n".utf8), Data("\(registration.nonce) P +1\nx".utf8)
        ] {
            XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, request), Data([AskpassProtocol.interactive]))
        }
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(ask(registration, passwordPrompt), Data([AskpassProtocol.password]) + secret, "Garbage didn't consume the password")
    }

    func testDeclinedHostKeyIsRecorded() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen { _ in .decline }
        await screen.attach(to: relay)
        let broker = broker(peer: ("/fixture/keel-askpass", 4242), relay: relay)
        defer { broker.stop() }
        let registration = try XCTUnwrap(broker.register(parent: { 4242 }, password: nil))
        XCTAssertEqual(ask(registration, PromptRelayTests.hostKeyText, kind: .typed(echo: true)), Data([AskpassProtocol.declined]))
        XCTAssertTrue(registration.activity.hostKeyDeclined)
        XCTAssertFalse(registration.activity.isAsking)
    }

    func testUnregisterWithdrawsOpenPrompts() async throws {
        let relay = PromptRelay()
        let screen = PromptScreen()  // never answers
        await screen.attach(to: relay)
        let broker = broker(peer: ("/fixture/keel-askpass", 4242), relay: relay)
        defer { broker.stop() }
        let registration = try XCTUnwrap(broker.register(parent: { 4242 }, password: nil))
        let path = registration.socketPath, request = AskpassProtocol.request(nonce: registration.nonce, kind: .typed(echo: false), prompt: "Verification code: ")
        let reply = Task.detached { AskpassHelper.exchange(path, request) }
        while screen.shown.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(registration.activity.isAsking)
        broker.unregister(registration)
        let answer = await reply.value
        XCTAssertEqual(answer, Data([AskpassProtocol.declined]))
        XCTAssertEqual(screen.events.last, .withdraw(screen.shown[0].id))
    }
}

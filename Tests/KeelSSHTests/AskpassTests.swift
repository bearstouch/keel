import Darwin
import KeelAskpass
import XCTest
@testable import KeelSSH

private final class ScriptedTerminal: AskpassTerminal {
    var answers: [String?]
    var asked: [(prompt: String, echo: Bool)] = []
    var shown: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    func show(_ text: String) { shown.append(text) }
    func ask(_ prompt: String, echo: Bool) -> String? {
        asked.append((prompt, echo))
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class AskpassTests: XCTestCase {
    private let secret = Data("s3cret-PASSWORD-VALUE".utf8)

    func testOnlyPasswordPromptsAreAnswerable() {
        XCTAssertEqual(AskpassPrompt.classify("deploy@prod's password: ", kind: nil), .password)
        XCTAssertEqual(AskpassPrompt.classify("(deploy@prod) Password:", kind: nil), .password)
        XCTAssertEqual(AskpassPrompt.classify("Enter passphrase for key '/Users/a/.ssh/id_ed25519': ", kind: nil), .typed(echo: false))
        XCTAssertEqual(
            AskpassPrompt.classify("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", kind: nil), .typed(echo: true),
            "Host-key trust is always typed by the person")
        XCTAssertEqual(AskpassPrompt.classify("New password:", kind: nil), .typed(echo: false))
        XCTAssertEqual(AskpassPrompt.classify("Verification code:", kind: nil), .typed(echo: false))
        XCTAssertEqual(AskpassPrompt.classify("deploy@prod's password: ", kind: "confirm"), .confirm)
        XCTAssertEqual(AskpassPrompt.classify("Confirm user presence for key", kind: "none"), .notice)
    }

    func testNonceFraming() {
        let nonce = AskpassProtocol.makeNonce()
        XCTAssertNotEqual(nonce, AskpassProtocol.makeNonce())
        let request = AskpassProtocol.request(nonce: nonce, kind: .typed(echo: true), prompt: "Continue (yes/no)? ")
        let line = request.prefix { $0 != 0x0A } + Data([0x0A])
        XCTAssertEqual(AskpassProtocol.header(from: line), AskpassProtocol.Header(nonce: nonce, kind: .typed(echo: true), length: 19))
        XCTAssertEqual(request.dropFirst(line.count), Data("Continue (yes/no)? ".utf8))
        for kind in [AskpassPrompt.password, .typed(echo: false), .confirm, .notice] {
            XCTAssertEqual(AskpassProtocol.header(from: AskpassProtocol.request(nonce: nonce, kind: kind))?.kind, kind)
        }
        XCTAssertNil(AskpassProtocol.header(from: Data("\(nonce) P 0".utf8)), "Unterminated")
        XCTAssertNil(AskpassProtocol.header(from: Data("short P 0\n".utf8)))
        XCTAssertNil(AskpassProtocol.header(from: Data((nonce.uppercased() + " P 0\n").utf8)))
        XCTAssertNil(AskpassProtocol.header(from: Data("\(nonce)\n".utf8)), "The kind and length are required")
        XCTAssertNil(AskpassProtocol.header(from: Data("\(nonce) P \(AskpassProtocol.promptLimit + 1)\n".utf8)))
        XCTAssertEqual(
            AskpassProtocol.request(nonce: nonce, prompt: String(repeating: "x", count: 9_000)).count, 64 + 8 + AskpassProtocol.promptLimit, "Long prompts are cut to the limit")
    }

    func testHelperWritesBrokerPasswordWithoutTouchingTerminal() {
        let terminal = ScriptedTerminal([])
        var output = Data(), sent: (String, Data)?
        var helper = AskpassHelper(
            arguments: ["keel-askpass", "deploy@prod's password: "],
            environment: [AskpassProtocol.socketVariable: "/tmp/s", AskpassProtocol.nonceVariable: AskpassProtocol.makeNonce()])
        helper.exchange = {
            sent = ($0, $1); return Data([AskpassProtocol.password]) + self.secret
        }
        helper.terminal = terminal
        helper.write = { output.append($0) }
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, secret + Data([0x0A]))
        XCTAssertEqual(sent?.0, "/tmp/s")
        XCTAssertTrue(terminal.asked.isEmpty)
    }

    func testHelperRelaysEveryPromptThroughTheBroker() {
        let environment = [AskpassProtocol.socketVariable: "/tmp/s", AskpassProtocol.nonceVariable: AskpassProtocol.makeNonce()]
        let terminal = ScriptedTerminal(["never used"])
        var helper = AskpassHelper(arguments: ["keel-askpass", "Are you sure you want to continue connecting (yes/no/[fingerprint])? "], environment: environment)
        var output = Data(), requests: [Data] = [], reply = Data([AskpassProtocol.password]) + Data("yes".utf8)
        helper.exchange = { _, request in
            requests.append(request); return reply
        }
        helper.terminal = terminal
        helper.write = { output.append($0) }
        XCTAssertEqual(helper.run(), 0, "Accepted in the sheet: ssh reads `yes`")
        XCTAssertEqual(output, Data("yes\n".utf8))
        XCTAssertEqual(AskpassProtocol.header(from: requests[0].prefix { $0 != 0x0A } + Data([0x0A]))?.kind, .typed(echo: true))
        XCTAssertTrue(String(decoding: requests[0], as: UTF8.self).hasSuffix("(yes/no/[fingerprint])? "), "ssh's text travels unchanged")

        reply = Data([AskpassProtocol.declined]); output = Data()
        XCTAssertEqual(helper.run(), 1, "Rejected: ssh's prompt fails")
        XCTAssertTrue(output.isEmpty)

        helper.environment["SSH_ASKPASS_PROMPT"] = "confirm"
        reply = Data([AskpassProtocol.password]) + Data("yes".utf8)
        XCTAssertEqual(helper.run(), 0, "Allowed confirm")
        reply = Data([AskpassProtocol.declined])
        XCTAssertEqual(helper.run(), 1, "Denied confirm")
        XCTAssertTrue(output.isEmpty, "A confirm answer is the exit status only")
        XCTAssertTrue(terminal.asked.isEmpty, "The broker's answer is final; the terminal isn't asked")
    }

    func testHelperFallsBackToTerminalForEverythingElse() {
        var helper = AskpassHelper(
            arguments: ["keel-askpass", "deploy@prod's password: "],
            environment: [AskpassProtocol.socketVariable: "/tmp/s", AskpassProtocol.nonceVariable: AskpassProtocol.makeNonce()])
        var output = Data(), exchanges = 0
        let terminal = ScriptedTerminal(["typed", "yes", nil])
        helper.exchange = { _, _ in
            exchanges += 1; return Data([AskpassProtocol.interactive])
        }
        helper.terminal = terminal
        helper.write = { output.append($0) }
        XCTAssertEqual(helper.run(), 0, "Refused by the broker: asked on the terminal, echo off")
        XCTAssertEqual(output, Data("typed\n".utf8))
        XCTAssertEqual(terminal.asked.last?.echo, false)

        helper.arguments = ["keel-askpass", "Are you sure you want to continue connecting (yes/no/[fingerprint])? "]
        output = Data()
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, Data("yes\n".utf8))
        XCTAssertEqual(exchanges, 2, "Trust prompts go to the broker first; `I` leaves them to the terminal")
        XCTAssertEqual(helper.run(), 1, "No terminal input fails the prompt")

        helper.environment = [:]
        helper.arguments = ["keel-askpass", "deploy@prod's password: "]
        terminal.answers = ["manual"]
        output = Data()
        XCTAssertEqual(helper.run(), 0)
        XCTAssertEqual(output, Data("manual\n".utf8), "Without broker variables the prompt is typed")
        XCTAssertEqual(exchanges, 3)
    }

    private func broker(peer: (path: String, parent: pid_t)?) -> AskpassBroker {
        let broker = AskpassBroker(helperPath: "/fixture/keel-askpass")
        broker.peerProcess = { _ in peer }
        return broker
    }

    func testBrokerAnswersOnceForTheSessionsHelper() throws {
        let broker = broker(peer: ("/fixture/keel-askpass", 4242))
        defer { broker.stop() }
        let calls = Counter(), secret = secret
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    calls.increment(); return secret
                }))
        var info = stat()
        XCTAssertEqual(lstat(registration.socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat((registration.socketPath as NSString).deletingLastPathComponent, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let request = AskpassProtocol.request(nonce: registration.nonce, prompt: "deploy@prod's password: ")
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, request), Data([AskpassProtocol.password]) + secret)
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, request), Data([AskpassProtocol.interactive]), "One saved answer per launch; without a relay the rest is left to the terminal")
        XCTAssertEqual(calls.count, 1)
        let environment = registration.environment(helper: broker.helperPath)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertFalse(environment.values.contains { $0.contains("s3cret") }, "The environment carries no secret")
    }

    func testBrokerRefusesOtherProcessesAndNonces() throws {
        let calls = Counter(), secret = secret
        for (peer, parent) in [(("/elsewhere/tool", pid_t(4242)), pid_t(4242)), (("/fixture/keel-askpass", 999), 4242), (("/fixture/keel-askpass", 4242), 7)] {
            let broker = broker(peer: peer)
            defer { broker.stop() }
            let registration = try XCTUnwrap(
                broker.register(
                    parent: { parent },
                    password: {
                        calls.increment(); return secret
                    }))
            XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce)), Data([AskpassProtocol.interactive]))
            XCTAssertEqual(broker.registeredCount, 0, "A refused request revokes the nonce")
        }
        let broker = broker(peer: ("/fixture/keel-askpass", 4242))
        defer { broker.stop() }
        let registration = try XCTUnwrap(
            broker.register(
                parent: { 4242 },
                password: {
                    calls.increment(); return secret
                }))
        XCTAssertEqual(
            AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: AskpassProtocol.makeNonce())), Data([AskpassProtocol.interactive]))
        broker.unregister(registration)
        XCTAssertEqual(AskpassHelper.exchange(registration.socketPath, AskpassProtocol.request(nonce: registration.nonce)), Data([AskpassProtocol.interactive]))
        XCTAssertEqual(calls.count, 0)
    }

    func testStopRemovesSocket() throws {
        let broker = broker(peer: nil)
        let registration = try XCTUnwrap(broker.register(parent: { nil }, password: { nil }))
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: (registration.socketPath as NSString).deletingLastPathComponent))
    }

    /// The real helper binary, run by a child shell standing in for ssh.
    func testBuiltHelperEndToEnd() throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(AskpassBroker.helperName).path
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Run `swift build` first to build \(AskpassBroker.helperName).") }
        let broker = AskpassBroker(helperPath: helper)
        defer { broker.stop() }
        let parent = Counter(), secret = secret
        // `; :` keeps sh from exec'ing the helper, so its parent is the stand-in ssh.
        let second = Process(), secondOutput = Pipe()
        second.executableURL = URL(fileURLWithPath: "/bin/sh")
        second.arguments = ["-c", "read go; \"$0\" \"deploy@prod's password: \"; :", helper]
        let gate = Pipe()
        second.standardInput = gate
        second.standardOutput = secondOutput
        let holder = PIDHolder()
        let registered = try XCTUnwrap(
            broker.register(
                parent: { holder.pid },
                password: {
                    parent.increment(); return secret
                }))
        second.environment = ProcessInfo.processInfo.environment.merging(registered.environment(helper: helper)) { $1 }
        try second.run()
        holder.pid = second.processIdentifier
        gate.fileHandleForWriting.write(Data("go\n".utf8))
        second.waitUntilExit()
        XCTAssertEqual(secondOutput.fileHandleForReading.readDataToEndOfFile(), secret + Data([0x0A]))
        XCTAssertEqual(parent.count, 1)
    }
}

private final class PIDHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var pid: Int32? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

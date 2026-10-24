import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

/// String keys with expiries on a fixed clock: answers `TYPE`, `GET`, `RENAME` / `RENAMENX`, `PEXPIRE` / `PEXPIREAT`,
/// `PERSIST`, `PTTL`, `PEXPIRETIME` (only as Redis 7 does, `hasExpireTime`) and `UNLINK` the way Redis does.
final class ExpiringKeyspace: @unchecked Sendable {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let nowMilliseconds: Int64 = 1_800_000_000_000

    private let lock = NSLock()
    private var values: [String: String]
    private var expiries: [String: Int64] = [:]
    let hasExpireTime: Bool
    private(set) lazy var server = RecordingServer { [unowned self] arguments in lock.withLock { answer(arguments) } }

    init(_ values: [String: String], hasExpireTime: Bool = true) { self.values = values; self.hasExpireTime = hasExpireTime }

    var keys: [String: String] { lock.withLock { values } }
    func expiry(_ key: String) -> Int64? { lock.withLock { expiries[key] } }
    func expire(_ key: String, atMilliseconds: Int64) { lock.withLock { expiries[key] = atMilliseconds } }
    /// Commands sent, without the capability probe's (it names Keel's own probe key).
    var commands: [[String]] { server.allCommands.filter { !($0.count > 1 && $0[1].hasPrefix("keel:probe:")) } }

    func service() -> DataCommandService { DataCommandService(session: server.session()) }

    private func answer(_ arguments: [String]) -> String {
        let key = arguments.count > 1 ? arguments[1] : ""
        func bulk(_ text: String) -> String { "$\(text.utf8.count)\r\n\(text)\r\n" }
        switch arguments[0] {
        case "TYPE": return values[key] == nil ? "+none\r\n" : "+string\r\n"
        case "GET": return values[key].map(bulk) ?? "$-1\r\n"
        case "RENAME", "RENAMENX":
            guard let value = values[key] else { return "-ERR no such key\r\n" }
            let target = arguments[2]
            if arguments[0] == "RENAMENX", values[target] != nil { return ":0\r\n" }
            values[key] = nil; values[target] = value
            expiries[target] = expiries.removeValue(forKey: key)
            return arguments[0] == "RENAME" ? "+OK\r\n" : ":1\r\n"
        case "PEXPIRE", "PEXPIREAT":
            guard values[key] != nil, let amount = Int64(arguments[2]) else { return ":0\r\n" }
            expiries[key] = arguments[0] == "PEXPIRE" ? Self.nowMilliseconds + amount : amount
            return ":1\r\n"
        case "PERSIST": return expiries.removeValue(forKey: key) == nil ? ":0\r\n" : ":1\r\n"
        case "PTTL":
            guard values[key] != nil else { return ":-2\r\n" }
            return ":\(expiries[key].map { $0 - Self.nowMilliseconds } ?? -1)\r\n"
        case "PEXPIRETIME":
            guard hasExpireTime else { return "-ERR unknown command 'PEXPIRETIME', with args beginning with: \r\n" }
            guard values[key] != nil else { return ":-2\r\n" }
            return ":\(expiries[key] ?? -1)\r\n"
        case "UNLINK":
            let removed = arguments.dropFirst().filter { values.removeValue(forKey: $0) != nil }.count
            return ":\(removed)\r\n"
        default: return "-ERR unexpected \(arguments[0])\r\n"
        }
    }
}

final class KeyActionsTests: XCTestCase {
    private let writable = DataContext(profile: SafetyProfile(name: "local", readOnly: false))
    private let clock: @Sendable () -> Date = { ExpiringKeyspace.now }
    /// Fixed so the clock time doesn't depend on the Mac running the tests.
    private let utc: Date.FormatStyle = {
        var style = Date.FormatStyle(date: .numeric, time: .standard, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        style.calendar = Calendar(identifier: .gregorian)
        return style
    }()

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testRenameUsesRenameNX() async throws {
        let keyspace = ExpiringKeyspace(["user:1": "Ada"])
        let outcome = try await KeyActions.rename(data("user:1"), to: data("user:2"), service: keyspace.service(), context: writable)
        XCTAssertEqual(outcome, .renamed)
        XCTAssertEqual(keyspace.commands, [["RENAMENX", "user:1", "user:2"]])
        XCTAssertEqual(keyspace.keys, ["user:2": "Ada"])
    }

    func testRenameOverwriteRequiresConfirmation() async throws {
        let keyspace = ExpiringKeyspace(["user:1": "Ada", "user:2": "Grace"])
        let service = keyspace.service()
        // AC1: onto an existing key without confirming, nothing changes.
        let outcome = try await KeyActions.rename(data("user:1"), to: data("user:2"), service: service, context: writable)
        guard case .targetExists(let token) = outcome else { return XCTFail("expected the overwrite question, got \(outcome)") }
        XCTAssertEqual(keyspace.keys, ["user:1": "Ada", "user:2": "Grace"])
        XCTAssertFalse(keyspace.commands.contains { $0.first == "RENAME" })

        // A yes given for another rename doesn't cover this one, and nothing is sent.
        let sent = keyspace.commands.count
        do {
            _ = try await KeyActions.rename(data("user:1"), to: data("user:3"), overwrite: token, service: service, context: writable)
            XCTFail("a confirmation for user:2 must not rename onto user:3")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        XCTAssertEqual(keyspace.commands.count, sent)

        // Confirmed: RENAME replaces the target.
        let replaced = try await KeyActions.rename(data("user:1"), to: data("user:2"), overwrite: token, service: service, context: writable)
        XCTAssertEqual(replaced, .renamed)
        XCTAssertEqual(keyspace.commands.last, ["RENAME", "user:1", "user:2"])
        XCTAssertEqual(keyspace.keys, ["user:2": "Ada"])
    }

    func testTTLPresetsAndAbsolute() async throws {
        XCTAssertEqual(KeyActions.TTLPreset.allCases.map(\.rawValue), ["1 min", "1 h", "1 day", "7 days"])
        XCTAssertEqual(KeyActions.TTLPreset.allCases.map(\.milliseconds), [60_000, 3_600_000, 86_400_000, 604_800_000])

        // Redis 7: PEXPIRE, then PEXPIRETIME gives the absolute time. AC2: 1 h shows the expiry clock time.
        let redis7 = ExpiringKeyspace(["k": "v"])
        let expiry = try await KeyActions.setTTL(data("k"), .preset(.hour), service: redis7.service(), context: writable, now: clock)
        XCTAssertEqual(expiry, .at(ExpiringKeyspace.now.addingTimeInterval(3_600)))
        // ICU puts a narrow no-break space before AM on newer macOS.
        XCTAssertEqual(expiry.text(style: utc).replacingOccurrences(of: "\u{202F}", with: " "), "1/15/2027, 9:00:00 AM")
        XCTAssertEqual(redis7.commands, [["PEXPIRE", "k", "3600000"], ["PEXPIRETIME", "k"]])

        // Redis 6: no PEXPIRETIME, so the time is now plus PTTL.
        let redis6 = ExpiringKeyspace(["k": "v"], hasExpireTime: false)
        let computed = try await KeyActions.setTTL(data("k"), .preset(.day), service: redis6.service(), context: writable, now: clock)
        XCTAssertEqual(computed, .at(ExpiringKeyspace.now.addingTimeInterval(86_400)))
        XCTAssertEqual(redis6.commands, [["PEXPIRE", "k", "86400000"], ["PTTL", "k"]])

        // An absolute date: PEXPIREAT in Unix milliseconds.
        let at = ExpiringKeyspace.now.addingTimeInterval(90.5)
        let absolute = try await KeyActions.setTTL(data("k"), .at(at), service: redis7.service(), context: writable, now: clock)
        XCTAssertEqual(absolute, .at(at))
        XCTAssertEqual(redis7.commands.suffix(2), [["PEXPIREAT", "k", "1800000090500"], ["PEXPIRETIME", "k"]])

        // Zero, negative or past would delete the key: refused with nothing sent.
        let sent = redis7.commands.count
        for change in [KeyActions.TTLChange.after(milliseconds: 0), .after(milliseconds: -5), .at(ExpiringKeyspace.now.addingTimeInterval(-1))] {
            do {
                _ = try await KeyActions.setTTL(data("k"), change, service: redis7.service(), context: writable, now: clock)
                XCTFail("\(change) must be refused")
            } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        }
        XCTAssertEqual(redis7.commands.count, sent)
        XCTAssertEqual(redis7.keys, ["k": "v"])
    }

    func testPersistRemovesTTL() async throws {
        let keyspace = ExpiringKeyspace(["k": "v"])
        keyspace.expire("k", atMilliseconds: 1_800_000_600_000)
        let expiry = try await KeyActions.setTTL(data("k"), .persist, service: keyspace.service(), context: writable, now: clock)
        XCTAssertEqual(expiry, .persistent)
        XCTAssertEqual(expiry.text(), "—")
        XCTAssertNil(keyspace.expiry("k"))
        XCTAssertEqual(keyspace.commands.first, ["PERSIST", "k"])
    }

    func testTTLOnGoneKeyFails() async {
        let keyspace = ExpiringKeyspace([:])
        do {
            _ = try await KeyActions.setTTL(data("gone"), .preset(.minute), service: keyspace.service(), context: writable, now: clock)
            XCTFail("PEXPIRE answering 0 means the key is gone")
        } catch { XCTAssertEqual(error, .invalidRequest("The key no longer exists.")) }
    }

    func testDeleteUsesUnlinkForOneKey() async throws {
        let keyspace = ExpiringKeyspace(["k": "v", "other": "w"])
        try await KeyActions.delete(data("k"), service: keyspace.service(), context: writable)
        XCTAssertEqual(keyspace.commands, [["UNLINK", "k"]])
        XCTAssertEqual(keyspace.keys, ["other": "w"])
    }

    func testReadOnlyProfileSendsNothing() async {
        let keyspace = ExpiringKeyspace(["k": "v"])
        let readOnly = DataContext(profile: SafetyProfile(name: "prod", readOnly: true))
        let service = keyspace.service()
        do {
            _ = try await KeyActions.rename(data("k"), to: data("k2"), service: service, context: readOnly)
            XCTFail("rename on a read-only profile")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        do {
            _ = try await KeyActions.setTTL(data("k"), .persist, service: service, context: readOnly, now: clock)
            XCTFail("persist on a read-only profile")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        do {
            try await KeyActions.delete(data("k"), service: service, context: readOnly)
            XCTFail("delete on a read-only profile")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        XCTAssertEqual(keyspace.commands, [])
        XCTAssertEqual(keyspace.keys, ["k": "v"])
    }

    func testRenameRefusesEmptyOrSameName() async {
        let keyspace = ExpiringKeyspace(["k": "v"])
        for name in ["", "k"] {
            do {
                _ = try await KeyActions.rename(data("k"), to: data(name), service: keyspace.service(), context: writable)
                XCTFail("renaming to \"\(name)\" must be refused")
            } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        }
        XCTAssertEqual(keyspace.commands, [])
    }
}

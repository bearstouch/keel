import Foundation
import KeelRESP
import XCTest

@testable import KeelCore

final class KeyDetailsTests: XCTestCase {
    private let key = Data("user:1".utf8)

    private func details(memory: Bool, answer: @escaping @Sendable ([String]) -> String) async -> (KeyDetails, RecordingServer) {
        let server = RecordingServer(answer: answer)
        let service = DataCommandService(session: server.session())
        let context = DataContext(profile: SafetyProfile(name: "local", readOnly: true))
        return (await KeyDetails.load(key: key, memory: memory, service: service, context: context), server)
    }

    func testUnavailableWhenUnsupported() async {
        // Dragonfly without OBJECT, an ACL user denied MEMORY: "unavailable", never an error.
        let (details, _) = await details(memory: true) { arguments in
            switch arguments.first {
            case "OBJECT": return "-ERR unknown command 'OBJECT'\r\n"
            case "MEMORY": return "-NOPERM this user has no permissions to run the 'memory|usage' command\r\n"
            case "PTTL": return ":-1\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
        XCTAssertEqual(details.encodingText, "unavailable")
        XCTAssertEqual(details.memoryText, "unavailable")
        XCTAssertEqual(details.ttlText, "No expiry")
    }

    func testShowsEncodingExactTTLAndMemoryOnlyOnRequest() async {
        let answer: @Sendable ([String]) -> String = { arguments in
            switch arguments.first {
            case "OBJECT": return "$8\r\nlistpack\r\n"
            case "MEMORY": return ":4213\r\n"
            case "PTTL": return ":90000\r\n"
            default: return "-ERR unexpected\r\n"
            }
        }
        let (first, server) = await details(memory: false, answer: answer)
        XCTAssertEqual(first.encodingText, "listpack")
        XCTAssertEqual(first.ttlText, "90,000 ms (1m 30s)")
        XCTAssertNil(first.memoryText, "memory waits for the user")
        XCTAssertFalse(server.allCommands.contains { $0.first == "MEMORY" })

        let (measured, _) = await details(memory: true, answer: answer)
        XCTAssertEqual(measured.memoryText, "4.1 KB (4,213 bytes)")
    }

    func testGoneKeyIsUnavailable() async {
        let (details, _) = await details(memory: true) { arguments in
            switch arguments.first {
            case "OBJECT", "MEMORY": return "$-1\r\n"
            default: return ":-2\r\n"
            }
        }
        XCTAssertEqual([details.encodingText, details.ttlText, details.memoryText], ["unavailable", "unavailable", "unavailable"])
    }

    func testMetadataLine() {
        XCTAssertEqual(KeyHeader(type: .hash, ttlMilliseconds: 3 * 86_400_000 + 5, length: 6, readOnly: false).metadataLine, "Expires in 3 days · 6 fields")
        XCTAssertEqual(KeyHeader(type: .stream, ttlMilliseconds: 1_000, length: 1, readOnly: true).metadataLine, "Expires in 1 second · 1 entry · Read-only")
        XCTAssertEqual(KeyHeader(type: .other, length: nil, readOnly: false).metadataLine, "No expiry")
        XCTAssertEqual(KeyHeader(type: .list, ttlMilliseconds: 5_400_000, length: 12_000, readOnly: false).metadataLine, "Expires in 1 hour · 12,000 items")
    }
}

final class EditorTransactionTests: XCTestCase {
    private let key = Data("k".utf8)

    func testRefusedWriteSendsNothing() async {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        do {
            _ = try await service.executeTransaction(
                [.stringSet(key: key, value: Data("v".utf8), keepTTL: true)], unchanged: nil,
                context: DataContext(profile: SafetyProfile(name: "prod", readOnly: true)))
            XCTFail("expected READ_ONLY")
        } catch { XCTAssertEqual(error.code, "READ_ONLY") }
        XCTAssertTrue(server.allCommands.isEmpty)
    }

    func testGuardReadMustBeARead() async {
        let server = RecordingServer()
        let service = DataCommandService(session: server.session())
        let guardWrite = WatchGuard(key: key, reads: [.persist(key: key)], expected: [.integer(0)])
        do {
            _ = try await service.executeTransaction(
                [.stringSet(key: key, value: Data("v".utf8), keepTTL: true)], unchanged: guardWrite,
                context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
            XCTFail("expected INVALID_PARAMS")
        } catch { XCTAssertEqual(error.code, "INVALID_PARAMS") }
        XCTAssertTrue(server.allCommands.isEmpty)
    }

    func testGuardReadErrorStopsBeforeQueueing() async throws {
        let server = RecordingServer { arguments in arguments.first == "GET" ? "-NOPERM no access\r\n" : "+OK\r\n" }
        let service = DataCommandService(session: server.session())
        let result = try await service.executeTransaction(
            [.stringSet(key: key, value: Data("v".utf8), keepTTL: true)],
            unchanged: WatchGuard(key: key, reads: [.get(key: key)], expected: [.bulkString(Data("old".utf8))]),
            context: DataContext(profile: SafetyProfile(name: "local", readOnly: false)))
        XCTAssertEqual(result.reply, .error(Data("NOPERM no access".utf8)))
        XCTAssertEqual(server.allCommands.map { $0.first ?? "" }, ["WATCH", "GET", "UNWATCH"])
    }
}

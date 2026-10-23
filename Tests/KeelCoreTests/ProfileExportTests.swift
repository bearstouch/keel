import XCTest
@testable import KeelCore

final class ProfileExportTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    func testExportHasNoSecretFields() async throws {
        let store = await fixture.store()
        let folder = try await store.createFolder(named: "Payments")
        let tls = ConnectionSettings(name: "prod", label: .red, host: "redis.example.com", port: 6380, username: "app", tls: TLSSettings(serverName: "redis.example.com"))
        let prod = try await store.create(tls, folderID: folder.id, password: Data("hunter2-secret".utf8))
        _ = try await store.setTLSSecret(prod.id, Data("p12-passphrase-secret".utf8), expectedRevision: prod.revision)
        _ = try await store.create(ConnectionSettings(name: "bastion", tunnel: .inline(destination: "ops", user: "deploy", port: 22, identityFile: "/Users/me/.ssh/id")))

        let data = try await store.export().encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["password", "passphrase", "token", "hasPassword", "hasTLSSecret", "secret", "revision"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "an export must not contain \(forbidden)")
        }
        // The file round-trips to the same profiles, folders and order.
        let decoded = try ProfileExport.decode(data)
        let document = await store.document
        XCTAssertEqual(decoded, ProfileExport(document))
        XCTAssertEqual(decoded.profiles.map(\.settings.name), ["prod", "bastion"])
        XCTAssertEqual(decoded.profiles.first { $0.id == prod.id }?.folderID, folder.id)
        XCTAssertEqual(decoded.folders, [ProfileExport.Folder(id: folder.id, name: "Payments")])
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(header["format"] as? String, "keel-profiles")
        XCTAssertEqual(header["schemaVersion"] as? Int, 1)
    }

    func testExportIsDeterministic() async throws {
        let store = await fixture.store()
        _ = try await store.create(.sample("a")); _ = try await store.create(.sample("b"))
        let first = try await store.export().encoded(), second = try await store.export().encoded()
        XCTAssertEqual(first, second)
    }

    func testDecodeRefusesFilesThatAreNotExports() throws {
        for text in [
            "not json", "[]", #"{"schemaVersion":1,"folders":[],"profiles":[]}"#, #"{"format":"keel-profiles","folders":[],"profiles":[]}"#,
            #"{"format":"other","schemaVersion":1,"folders":[],"profiles":[]}"#, #"{"format":"keel-profiles","schemaVersion":0,"folders":[],"profiles":[]}"#
        ] {
            XCTAssertThrowsError(try ProfileExport.decode(Data(text.utf8)), text) { XCTAssertEqual($0 as? ProfileImportError, .notAnExport, text) }
        }
        XCTAssertThrowsError(try ProfileExport.decode(Data(count: ProfileExport.byteLimit + 1))) { XCTAssertEqual($0 as? ProfileImportError, .tooLarge) }
    }

    func testDecodeValidatesEveryRecord() throws {
        let id = UUID(), folder = UUID()
        func file(_ profiles: String, folders: String = "[]") -> Data {
            Data(#"{"format":"keel-profiles","schemaVersion":1,"folders":\#(folders),"profiles":\#(profiles)}"#.utf8)
        }
        let hostile = #"[{"id":"\#(id)","settings":{"name":"x","label":"none","host":"-oProxyCommand=id","port":6379,"database":0,"readOnly":false,"reconnectOnLaunch":false}}]"#
        XCTAssertThrowsError(try ProfileExport.decode(file(hostile))) { XCTAssertEqual($0 as? ProfileImportError, .invalid(.host)) }
        let orphan = #"[{"id":"\#(id)","folderID":"\#(folder)","settings":{"name":"x","label":"none","host":"h","port":6379,"database":0,"readOnly":false,"reconnectOnLaunch":false}}]"#
        XCTAssertThrowsError(try ProfileExport.decode(file(orphan))) { XCTAssertEqual($0 as? ProfileImportError, .invalid(.folder)) }
        let twice = #"[{"id":"\#(folder)","name":"A"},{"id":"\#(folder)","name":"B"}]"#
        XCTAssertThrowsError(try ProfileExport.decode(file("[]", folders: twice))) { XCTAssertEqual($0 as? ProfileImportError, .invalid(nil)) }
        XCTAssertThrowsError(try ProfileExport.decode(file(#"[{"id":"nope"}]"#))) { XCTAssertEqual($0 as? ProfileImportError, .invalid(nil)) }
    }
}

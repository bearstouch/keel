import XCTest
@testable import KeelCore

final class ProfileCodecTests: XCTestCase {
    private var fixture: ProfileFixture!

    override func setUpWithError() throws { fixture = try ProfileFixture() }
    override func tearDown() { fixture.remove() }

    func testEncodedFileHasNoSecrets() async throws {
        let store = await fixture.store()
        let password = "pa55-Very-Secret-7f3a", tlsPassphrase = "tls-Passphrase-91c2"
        var settings = ConnectionSettings(name: "payments-prod", label: .red, host: "redis.internal", username: "app", tls: TLSSettings(serverName: "redis.internal", caFile: "/etc/ca.pem"))
        settings.tunnel = .inline(destination: "bastion", user: "ops", port: 2222, identityFile: "/Users/me/.ssh/id_ed25519")
        let profile = try await store.create(settings, password: Data(password.utf8))
        _ = try await store.update(profile.id, settings, identity: .set(.fake(passphrase: tlsPassphrase)), expectedRevision: profile.revision)
        let copy = try await store.duplicate(profile.id)
        var renamed = copy.settings; renamed.name = "copy"
        _ = try await store.update(copy.id, renamed, password: .set(Data("second-Secret-55".utf8)), expectedRevision: copy.revision)

        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["connections.json", "connections.backup.json"])
        for file in files {
            let bytes = try Data(contentsOf: file)
            for secret in [password, tlsPassphrase, "second-Secret-55"] {
                XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(file.lastPathComponent) must not contain a secret")
                XCTAssertNil(bytes.range(of: Data(secret.utf8).base64EncodedData()), "nor its base64 form")
            }
            let text = String(decoding: bytes, as: UTF8.self).lowercased()
            for word in ["\"password\"", "passphrase", "token"] { XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) has no \(word) field") }
        }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any])
        let stored = try XCTUnwrap(raw["profiles"] as? [[String: Any]])
        XCTAssertEqual(stored.map { $0["hasPassword"] as? Bool }, [true, true], "only flags record which secrets exist")
        XCTAssertEqual(stored.first?["hasTLSSecret"] as? Bool, true)
        XCTAssertEqual(raw["schemaVersion"] as? Int, 1)
    }

    func testRoundTripAndHandEditedFilesAreRejected() throws {
        let folder = ProfileFolder(id: UUID(), name: "Ops", revision: 1)
        var settings = ConnectionSettings(name: "x", tunnel: .savedHost(id: UUID()))
        settings.separator = "|"; settings.connectTimeoutMilliseconds = 2000; settings.clientName = "keel"
        let profile = ConnectionProfile(id: UUID(), settings: settings, folderID: folder.id, revision: 2, hasPassword: true)
        let document = ConnectionsDocument(revision: 2, folders: [folder], profiles: [profile])
        XCTAssertEqual(try PersistenceCodec.decode(ConnectionsDocument.self, from: PersistenceCodec.encode(document)), document)

        func rejects(_ change: (inout ConnectionsDocument) -> Void, _ reason: String) {
            var edited = document; change(&edited)
            XCTAssertThrowsError(try PersistenceCodec.decode(ConnectionsDocument.self, from: PersistenceCodec.encode(edited)), reason) {
                XCTAssertEqual($0 as? PersistenceError, .corrupt, reason)
            }
        }
        rejects({ $0.profiles.append($0.profiles[0]) }, "duplicate IDs")
        rejects({ $0.profiles[0].revision = 9 }, "a record revision above the document's")
        rejects(
            {
                $0.profiles[0].connectionRevision = 3; $0.revision = 3
            }, "a connection revision above the record's")
        rejects({ $0.profiles[0].folderID = UUID() }, "a missing folder")
        rejects({ $0.profiles[0].settings.host = "-oProxyCommand=id" }, "an option-like host")
        rejects({ $0.labels[0].name = "" }, "an empty label name")

        // Labels missing from the file get their defaults, and Production stays production.
        let partial = #"{"schemaVersion":1,"revision":0,"folders":[],"profiles":[],"labels":[{"color":"red","name":"Live","treatAsProduction":false}]}"#
        let decoded = try PersistenceCodec.decode(ConnectionsDocument.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.labels.map(\.color), LabelColor.allCases)
        XCTAssertEqual(decoded.label(.red), ProfileLabel(color: .red, name: "Live", treatAsProduction: true))
        XCTAssertEqual(decoded.label(.blue).name, "Blue")
    }
}

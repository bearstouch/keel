import Foundation
import XCTest

@testable import KeelCore
@testable import KeelUI

/// A Keychain-free importer: `.p12` passphrase "right", PEM keys containing "ENCRYPTED" need it too.
final class FakeIdentityImporter: TLSIdentityImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var imported: [ImportedTLSIdentity] = []
    private var discardedReferences: [Data] = []
    var imports: [ImportedTLSIdentity] { lock.withLock { imported } }
    var discarded: [Data] { lock.withLock { discardedReferences } }

    private func make(_ summary: String, passphrase: String?) -> ImportedTLSIdentity {
        let identity = ImportedTLSIdentity(reference: Data(UUID().uuidString.utf8), summary: summary, isNew: true, passphrase: passphrase)
        lock.withLock { imported.append(identity) }
        return identity
    }

    func importPKCS12(_ data: Data, passphrase: String) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        guard passphrase == "right" else { throw .wrongPassphrase }
        return make("p12-client", passphrase: passphrase)
    }

    func importPEM(certificate: Data, privateKey: Data, passphrase: String?) throws(TLSIdentityImportError) -> ImportedTLSIdentity {
        guard String(decoding: certificate, as: UTF8.self).contains("CERTIFICATE") else { throw .unreadableCertificate }
        if String(decoding: privateKey, as: UTF8.self).contains("ENCRYPTED") {
            guard let passphrase else { throw .passphraseRequired }
            guard passphrase == "right" else { throw .wrongPassphrase }
        }
        return make("pem-client", passphrase: passphrase)
    }

    func discard(_ identity: ImportedTLSIdentity) { lock.withLock { discardedReferences.append(identity.reference) } }
    func subject(profileID: UUID) -> String? { "saved-client" }
}

@MainActor
final class ClientIdentityImportTests: XCTestCase {
    private var directory: URL!
    private let importer = FakeIdentityImporter()
    private let secrets = MemorySecretStore()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keel-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func store() async -> ProfileStore {
        let store = ProfileStore(directory: directory.appendingPathComponent("state"), secrets: secrets)
        _ = await store.load()
        return store
    }

    private func sheet(_ mode: ConnectionSheetModel.Mode, store: ProfileStore) -> ConnectionSheetModel {
        let model = ConnectionSheetModel(mode: mode, tester: FakeConnectionTester(), store: store, identities: importer)
        model.tlsEnabled = true
        return model
    }

    func testP12AsksForItsPassphraseAndIsSavedWithTheProfile() async throws {
        let store = await store()
        let model = sheet(.create(folderID: nil), store: store)
        XCTAssertTrue(model.canImportIdentity)
        await model.importIdentity(from: [try file("client.p12", "binary")])
        XCTAssertEqual(model.identityPassphrasePrompt, .pkcs12)
        XCTAssertTrue(importer.imports.isEmpty, "nothing reaches the Keychain before the passphrase")

        model.identityPassphrase = "wrong"
        await model.submitIdentityPassphrase()
        XCTAssertEqual(model.identityPassphrasePrompt, .pkcs12, "the prompt stays for another try")
        XCTAssertEqual(model.identityMessage, "The passphrase is wrong.")
        XCTAssertEqual(model.identityPassphrase, "", "cleared after each attempt")

        model.identityPassphrase = "right"
        await model.submitIdentityPassphrase()
        XCTAssertNil(model.identityPassphrasePrompt)
        XCTAssertEqual(model.clientIdentitySubject, "p12-client")
        let identity = try XCTUnwrap(importer.imports.first)

        let result = await model.save()
        let profile = try XCTUnwrap(result)
        XCTAssertTrue(profile.hasTLSSecret)
        let item = try XCTUnwrap(secrets.item(.tls, profile.id))
        XCTAssertEqual(try JSONDecoder().decode(TLSIdentitySecret.self, from: item).identity, identity.reference)
        await model.waitForIdentityWork()
        XCTAssertTrue(importer.discarded.isEmpty, "a saved identity is never discarded")
    }

    func testPEMPairImportsAtOnceAndAnEncryptedKeyAsks() async throws {
        let store = await store()
        let model = sheet(.create(folderID: nil), store: store)
        let certificate = try file("client.pem", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
        // Either order: the certificate is the file with a CERTIFICATE block.
        await model.importIdentity(from: [try file("client.key", "-----BEGIN PRIVATE KEY-----"), certificate])
        XCTAssertNil(model.identityPassphrasePrompt)
        XCTAssertEqual(model.clientIdentitySubject, "pem-client")
        let first = try XCTUnwrap(importer.imports.first)

        await model.importIdentity(from: [certificate, try file("encrypted.key", "-----BEGIN ENCRYPTED PRIVATE KEY-----")])
        XCTAssertEqual(model.identityPassphrasePrompt, .privateKey)
        model.identityPassphrase = "right"
        await model.submitIdentityPassphrase()
        XCTAssertEqual(importer.imports.count, 2)
        await model.waitForIdentityWork()
        XCTAssertEqual(importer.discarded, [first.reference], "the replaced import leaves the Keychain")
    }

    func testCancelDiscardsAnImportAndSavesNothing() async throws {
        let store = await store()
        let model = sheet(.create(folderID: nil), store: store)
        await model.importIdentity(from: [try file("both.pem", "-----BEGIN CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----")])
        let identity = try XCTUnwrap(importer.imports.first)
        model.cancel()
        await model.waitForIdentityWork()
        XCTAssertEqual(importer.discarded, [identity.reference])
        XCTAssertEqual(secrets.itemCount, 0)
    }

    func testEditShowsTheSavedSubjectAndRemoveRemovesItOnSave() async throws {
        let store = await store()
        let created = try await store.create(ConnectionSettings(name: "tls", tls: TLSSettings()), identity: .init(reference: Data("ref".utf8), summary: "x", isNew: true, passphrase: nil))
        let model = sheet(.edit(created), store: store)
        XCTAssertEqual(model.clientIdentity, .saved(subject: nil))
        await model.loadIdentitySubject()
        XCTAssertEqual(model.clientIdentitySubject, "saved-client")
        model.removeIdentity()
        XCTAssertFalse(model.hasClientIdentity)
        let result = await model.save()
        let saved = try XCTUnwrap(result)
        XCTAssertFalse(saved.hasTLSSecret)
        XCTAssertNil(secrets.item(.tls, created.id))
    }

    func testFileChoicesThatAreRefused() async throws {
        let store = await store()
        let model = sheet(.create(folderID: nil), store: store)
        let a = try file("a.pem", "x"), b = try file("b.pem", "x"), c = try file("c.pem", "x")
        await model.importIdentity(from: [a, b, c])
        XCTAssertEqual(model.identityMessage, "Choose a .p12 file, or a certificate and its private key.")
        await model.importIdentity(from: [try file("client.p12", "x"), a])
        XCTAssertEqual(model.identityMessage, "Choose a .p12 file, or a certificate and its private key.")
        let large = directory.appendingPathComponent("large.pem")
        try Data(count: ConnectionSheetModel.identityFileByteLimit + 1).write(to: large)
        await model.importIdentity(from: [large])
        XCTAssertEqual(model.identityMessage, "“large.pem” couldn't be read, or is larger than 1 MB.")
        await model.importIdentity(from: [a])
        XCTAssertEqual(model.identityMessage, "The certificate couldn't be read. Choose a PEM or DER certificate, or a .p12.")
        XCTAssertTrue(importer.imports.isEmpty)
        XCTAssertEqual(model.clientIdentity, .none)
    }

    func testWithoutAnImporterTheRowIsHidden() async {
        let model = ConnectionSheetModel(mode: .create(folderID: nil), tester: FakeConnectionTester(), store: await store())
        XCTAssertFalse(model.canImportIdentity)
    }
}

import Foundation
import KeelSSH
import XCTest

@testable import KeelCore

/// A `--fixture` run never reads or writes the login Keychain (getting-started → Launch arguments, MAC-22).
final class LaunchSecretsTests: XCTestCase {
    func testFixtureKeepsEverySecretInMemory() throws {
        let secrets = LaunchSecrets(arguments: LaunchArguments(fixture: true))
        XCTAssertFalse(secrets.usesKeychain)
        XCTAssertTrue(secrets.profiles is InMemorySecretStore)
        XCTAssertTrue(secrets.hosts is InMemoryHostSecretStore)
        XCTAssertNil(secrets.clientIdentity(UUID()), "No client identity without a keychain")
        XCTAssertNil(secrets.identities.subject(profileID: UUID()))
        // A client certificate can't live in memory: the import is refused with the reason, nothing is added.
        XCTAssertThrowsError(try NoTLSIdentityKeychain().importPKCS12(Data(), passphrase: "", certificate: nil)) {
            XCTAssertEqual($0 as? TLSIdentityImportError, .unsupportedKey(NoTLSIdentityKeychain.message))
        }

        let id = UUID()
        try secrets.profiles.write(Data("secret".utf8), .password, profileID: id)
        XCTAssertEqual(try secrets.profiles.read(.password, profileID: id), Data("secret".utf8))
        XCTAssertNil(try secrets.profiles.read(.tls, profileID: id), "Each service is its own item")
        try secrets.profiles.remove(.password, profileID: id)
        XCTAssertNil(try secrets.profiles.read(.password, profileID: id))

        try secrets.hosts.store(Data("ssh".utf8), hostID: id)
        XCTAssertEqual(try secrets.hosts.read(hostID: id), Data("ssh".utf8))
        secrets.hosts.remove(hostID: id)
        XCTAssertNil(try secrets.hosts.read(hostID: id))
        // A second fixture run starts empty: nothing outlives the process.
        XCTAssertNil(try LaunchSecrets(arguments: LaunchArguments(fixture: true)).hosts.read(hostID: id))
    }

    func testOtherRunsUseTheKeychain() {
        for arguments in [LaunchArguments(), LaunchArguments(stateDirectory: URL(fileURLWithPath: "/tmp/keel-demo", isDirectory: true))] {
            let secrets = LaunchSecrets(arguments: arguments)
            XCTAssertTrue(secrets.usesKeychain)
            XCTAssertTrue(secrets.profiles is KeychainSecretStore)
            XCTAssertTrue(secrets.hosts is KeychainHostSecretStore)
        }
    }
}

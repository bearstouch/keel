import XCTest
@testable import KeelSSH

/// The vendored host-library format, decoded under Keel names (KEEL-002).
final class HostLibraryCodecTests: XCTestCase {
    func testLoadsVersion1() throws {
        let id = UUID()
        let json = """
            {"schemaVersion":1,"revision":4,"hosts":[{"id":"\(id.uuidString)","name":"Bastion","destination":"bastion.example.com",\
            "user":"deploy","port":2222,"identityFile":"/Users/me/.ssh/id_ed25519","tags":["prod"],"revision":3,"connectionRevision":2,\
            "savedPassword":{"requiresUserPresence":true}}]}
            """
        let (hosts, revision) = try HostLibraryCodec.decode(Data(json.utf8))
        XCTAssertEqual(revision, 4)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.id, id)
        XCTAssertEqual(host.name, "Bastion")
        XCTAssertEqual(host.revision, 3)
        XCTAssertEqual(host.connectionRevision, 2)
        XCTAssertEqual(host.savedPassword, SavedPasswordPolicy(requiresUserPresence: true))
        XCTAssertEqual(host.sshArguments(options: ["-N"]), ["-p", "2222", "-l", "deploy", "-i", "/Users/me/.ssh/id_ed25519", "-N", "--", "bastion.example.com"])
        // Round-trips through the encoder unchanged.
        XCTAssertEqual(try HostLibraryCodec.decode(try HostLibraryCodec.encode(hosts, revision: revision)).hosts, hosts)
    }

    func testRejectsOtherVersionsAndDuplicateIDs() throws {
        let id = UUID().uuidString
        let host = #"{"id":"\#(id)","name":"A","destination":"a","tags":[],"revision":1}"#
        for json in [
            #"{"schemaVersion":2,"revision":1,"hosts":[]}"#,
            #"{"schemaVersion":0,"revision":1,"hosts":[]}"#,
            #"{"schemaVersion":1,"revision":1,"hosts":[\#(host),\#(host)]}"#
        ] {
            XCTAssertThrowsError(try HostLibraryCodec.decode(Data(json.utf8)), json) { XCTAssertEqual($0 as? HostLibraryError, .readOnly) }
        }
    }
}

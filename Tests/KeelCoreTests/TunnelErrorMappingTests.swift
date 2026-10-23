import Darwin
import Foundation
import KeelCore
import KeelSSH
import XCTest

/// FR-CN10 `TUNNEL_FAILED` and `TIMEOUT` (tunnel phase) for KEEL-009's AC4.
final class TunnelErrorMappingTests: XCTestCase {
    func testForwardFailureReportsExitStatusAndLastStderrLine() {
        let exit = TunnelExit(status: .exited(255), lastErrorLine: "Error: local forwarding failed")
        let failure = ConnectionFailure(tunnel: .exited(exit), destination: "ops")
        XCTAssertEqual(failure.category, .tunnelFailed)
        XCTAssertEqual(failure.category.rawValue, "TUNNEL_FAILED")
        XCTAssertEqual(failure.message, "ssh to ops exited with status 255: Error: local forwarding failed")
        XCTAssertEqual(failure.tunnelExit, exit)
        XCTAssertEqual(failure.suggestion, "Check the Redis host and port as seen from the SSH server.")
    }

    func testSuggestionsFollowSSHMessage() {
        func suggestion(_ line: String?) -> String {
            ConnectionFailure(tunnel: .exited(TunnelExit(status: .exited(255), lastErrorLine: line)), destination: "ops").suggestion
        }
        XCTAssertTrue(suggestion("Host key verification failed.").contains("known_hosts"))
        XCTAssertTrue(suggestion("deploy@ops: Permission denied (publickey).").contains("SSH user"))
        XCTAssertTrue(suggestion("ssh: Could not resolve hostname ops: nodename nor servname provided").contains("DNS"))
        XCTAssertEqual(suggestion(nil), "Check that `ssh ops` works in Terminal.")
        XCTAssertEqual(ConnectionFailure(tunnel: .exited(TunnelExit(status: .signaled(9), lastErrorLine: nil)), destination: "ops").message, "ssh to ops was stopped by signal 9.")
    }

    func testOtherTunnelErrors() {
        let timeout = ConnectionFailure(tunnel: .timeout(.seconds(10)), destination: "ops")
        XCTAssertEqual(timeout.category, .timeout)
        XCTAssertEqual(timeout.phase, .tunnel)
        XCTAssertTrue(timeout.message.contains("(tunnel)"), timeout.message)

        let injected = ConnectionFailure(tunnel: .invalidArguments(.invalidDestination), destination: "-oProxyCommand=id")
        XCTAssertEqual(injected.category, .tunnelFailed)
        XCTAssertFalse(injected.message.contains("ProxyCommand"), "Rejected text is never echoed")
        XCTAssertEqual(ConnectionFailure(tunnel: .launchFailed(ENOENT), destination: "ops").category, .tunnelFailed)
        XCTAssertEqual(ConnectionFailure(tunnel: .runtimeDirectory(.unsafe), destination: "ops").category, .tunnelFailed)
    }
}

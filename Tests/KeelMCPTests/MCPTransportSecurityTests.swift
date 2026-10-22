import XCTest
@testable import KeelMCP

/// Request checks extracted from Trellis's MCP endpoint (KEEL-002); the endpoint itself arrives with KEEL-045.
final class MCPTransportSecurityTests: XCTestCase {
    func testHostAndOriginHelpers() {
        for host in ["127.0.0.1", "127.0.0.1:7778", "localhost", "LOCALHOST:1", "[::1]", "[::1]:7778", "127.9.9.9"] {
            XCTAssertTrue(MCPTransportSecurity.isLoopbackHost(host), host)
        }
        for host in ["evil.example", "192.168.1.2:7778", "localhost.evil.example", "[::2]:1", "127.0.0.1.nip.io", ""] {
            XCTAssertFalse(MCPTransportSecurity.isLoopbackHost(host), host)
        }
        XCTAssertTrue(MCPTransportSecurity.isLoopbackOrigin("http://127.0.0.1:3000"))
        XCTAssertTrue(MCPTransportSecurity.isLoopbackOrigin("https://[::1]"))
        XCTAssertFalse(MCPTransportSecurity.isLoopbackOrigin("file://"))
        XCTAssertFalse(MCPTransportSecurity.isLoopbackOrigin("http://127.0.0.1.evil.example"))
    }

    func testBearerExtraction() {
        func request(_ value: String?) -> HTTPRequest { HTTPRequest(method: "POST", path: "/mcp", headers: value.map { ["Authorization": $0] } ?? [:]) }
        XCTAssertEqual(MCPTransportSecurity.bearer(request("Bearer kel_abc")), "kel_abc")
        XCTAssertEqual(MCPTransportSecurity.bearer(request("bearer   kel_abc  ")), "kel_abc")
        XCTAssertNil(MCPTransportSecurity.bearer(request(nil)))
        XCTAssertNil(MCPTransportSecurity.bearer(request("Bearer ")))
        XCTAssertNil(MCPTransportSecurity.bearer(request("Basic a2VsOng=")))
    }

    func testTokensCompareByHash() {
        let hash = MCPTransportSecurity.hash("kel_abc")
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(MCPTransportSecurity.constantTimeEqual(hash, MCPTransportSecurity.hash("kel_abc")))
        XCTAssertFalse(MCPTransportSecurity.constantTimeEqual(hash, MCPTransportSecurity.hash("kel_abd")))
        XCTAssertFalse(MCPTransportSecurity.constantTimeEqual(hash, hash.prefix(31)))
    }

    func testIPAddressLiterals() {
        XCTAssertEqual(IPAddressLiteral("127.0.0.2")?.isLoopback, true)
        XCTAssertEqual(IPAddressLiteral("::1")?.isLoopback, true)
        XCTAssertEqual(IPAddressLiteral("0.0.0.0")?.isLoopback, false, "Wildcard binds are network binds")
        XCTAssertEqual(IPAddressLiteral("::")?.isLoopback, false)
        XCTAssertEqual(IPAddressLiteral("10.0.0.5")?.isLoopback, false)
        for invalid in ["localhost", "", "fe80::1%en0", "1.2.3", "::1::"] { XCTAssertNil(IPAddressLiteral(invalid), invalid) }
    }
}

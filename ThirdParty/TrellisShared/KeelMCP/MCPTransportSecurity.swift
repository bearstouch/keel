import CryptoKit
import Foundation

/// Request checks the MCP endpoint applies before any JSON-RPC handling (05 API): bearer extraction,
/// token hashing with a constant-time compare, and the Host/Origin checks against DNS rebinding.
/// The endpoint itself (sessions, tools) is built on Keel's control layer in KEEL-045.
public enum MCPTransportSecurity {
    /// The token of an `Authorization: Bearer …` header; nil when missing, malformed or empty.
    public static func bearer(_ request: HTTPRequest) -> String? {
        guard let value = request.header("authorization"), value.count > 7, value.prefix(7).lowercased() == "bearer " else { return nil }
        let token = value.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Tokens are kept and compared only as SHA-256 hashes.
    public static func hash(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }

    /// Timing does not depend on where two equal-length values differ.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// `localhost`, `127.0.0.0/8` or `::1`, with an optional port.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("[") {
            guard let close = name.firstIndex(of: "]") else { return false }
            name = String(name[name.index(after: name.startIndex)..<close])
        } else if let colon = name.lastIndex(of: ":"), name.firstIndex(of: ":") == colon {
            name = String(name[..<colon])
        }
        if name == "localhost" { return true }
        guard name.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return false }
        return IPAddressLiteral(name)?.isLoopback ?? false
    }

    /// A browser page must never drive the API, whatever address it resolved: only loopback http(s) origins pass.
    public static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return false }
        return isLoopbackHost(host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)
    }
}

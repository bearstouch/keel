import Darwin
import Foundation

/// A parsed IPv4 or IPv6 literal. The MCP interface is always a literal, never a hostname,
/// so binding cannot depend on name resolution (FR-RC02).
public enum IPAddressLiteral: Equatable, Sendable {
    case v4(in_addr_t)
    case v6([UInt8])

    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self = .v4(v4.s_addr)
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
        } else {
            return nil
        }
    }

    public var isLoopback: Bool {
        switch self {
        case .v4(let address): UInt32(bigEndian: address) >> 24 == 127
        case .v6(let bytes): bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }
}

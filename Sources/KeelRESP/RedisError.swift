import Foundation

/// Why a transport stopped or never became ready. Carries OS codes only, never bytes from the peer, so it is safe to
/// show and to map onto FR-CN10 categories (POSIX 61 → `CONNECTION_REFUSED`, any DNS code → `DNS_FAILED`).
public enum TransportError: Error, Equatable, Sendable {
    case posix(Int32)
    case dns(Int32)
    case tls(Int32)
    /// The peer closed the stream.
    case closed
    /// Keel cancelled the transport.
    case cancelled
    case other
}

/// Which step ran out of time: `connect` is TCP (or the Unix socket), `auth` any handshake command. TLS and tunnel
/// phases join with their stories.
public enum TimeoutPhase: String, Sendable { case connect, auth, command }

/// A `RedisConnection` failure. Server error replies (`-ERR …`) are not errors here: they come back as
/// `RESPValue.error` and are interpreted above the protocol layer.
public enum RedisError: Error, Equatable, Sendable {
    /// The connection isn't ready (never connected, closed or failed); nothing was sent.
    case notConnected
    /// Connecting failed.
    case connectionFailed(TransportError)
    /// The connection ended while a read was in flight; reads are safe to retry on a new connection.
    case connectionLost
    case timeout(TimeoutPhase)
    /// The connection ended after a write was sent and before its reply arrived. Re-read; never re-send (NFR-RL03).
    case outcomeUnknown
    /// The caller stopped waiting, or Keel closed the connection, before a read's reply arrived.
    case cancelled
    /// The reply stream was malformed or over a limit; the connection is closed.
    case codec(RESPError)
    /// A reply arrived with no command waiting for it; the stream can't be trusted any more.
    case unexpectedReply

    /// The shared API error code (`specs/05-api.md#errors`).
    public var code: String {
        switch self {
        case .notConnected: return "NOT_CONNECTED"
        case .connectionFailed, .connectionLost: return "CONNECTION_FAILED"
        case .timeout: return "TIMEOUT"
        case .outcomeUnknown: return "OUTCOME_UNKNOWN"
        case .cancelled: return "CANCELLED"
        case .codec(let error): return error.code
        case .unexpectedReply: return "PROTOCOL_ERROR"
        }
    }
}

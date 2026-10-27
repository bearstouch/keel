import Foundation

/// Why a transport stopped or never became ready. Carries OS codes, plus sanitized certificate names for a refused
/// chain, never stream bytes, so it is safe to show and to map onto FR-CN10 categories (POSIX 61 →
/// `CONNECTION_REFUSED`, any DNS code → `DNS_FAILED`, a refused chain → `TLS_UNTRUSTED` / `TLS_HOSTNAME_MISMATCH`).
public enum TransportError: Error, Equatable, Sendable {
    case posix(Int32)
    case dns(Int32)
    /// A TLS handshake failure (`errSSL…` OSStatus) other than Keel's own verify block refusing the chain.
    case tls(Int32)
    /// Keel's verify block refused the server's certificate chain.
    case tlsRejected(TLSTrustFailure)
    /// TLS didn't come up, and a plain `PING` to the same port got a RESP reply: the server isn't using TLS.
    case plaintextServer
    /// The peer closed the stream.
    case closed
    /// Keel cancelled the transport.
    case cancelled
    case other
}

/// Which step ran out of time: `tunnel` is the SSH tunnel becoming ready, `connect` is TCP (or the Unix socket) plus
/// the TLS handshake, `auth` any handshake command.
public enum TimeoutPhase: String, Sendable { case tunnel, connect, auth, command }

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

    /// The shared error code (`docs/architecture.md#errors`).
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

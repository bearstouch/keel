import Foundation
import Network
import Security

/// A client certificate and its private key, resolved from the Keychain by persistent reference (INT-05).
/// `SecIdentity` is an immutable Core Foundation object, so sharing it across threads is safe.
public struct TLSClientIdentity: @unchecked Sendable, Equatable {
    public let identity: SecIdentity
    public init(_ identity: SecIdentity) { self.identity = identity }
}

/// Why the verify block refused a server's certificate. Names come from the peer's certificates, so they are
/// sanitized (no control characters, bounded length and count) before anyone shows them.
public enum TLSTrustFailure: Error, Sendable, Equatable {
    /// The chain doesn't end in a trusted root: the system roots, or only the custom CA when one is selected.
    case untrusted(issuer: String, customCA: Bool)
    /// The chain is trusted but issued for other names.
    case hostnameMismatch(expected: String, certificateNames: [String])
    /// Nothing to match the certificate against: a Unix-socket endpoint without a server name override.
    case noServerName
}

/// TLS for one connection (FR-CN03, INT-05, NFR-SC02), mapped onto `sec_protocol_options`: TLS 1.2 or later, SNI,
/// an optional client identity, and a verify block that checks the chain against the system roots or, with a custom
/// CA, against that CA only. Verification is on unless `skipVerification` is set, which callers must surface.
public struct TLSConfiguration: Sendable, Equatable {
    public static let minimumVersion = tls_protocol_version_t.TLSv12

    /// SNI and the name the certificate must match; nil uses the TCP host. Overrides matter for tunnels and IP hosts.
    public var serverName: String?
    /// DER certificates of the custom CA bundle. Non-empty means anchor-only trust: system roots aren't consulted.
    public var anchorCertificates: [Data]
    public var clientIdentity: TLSClientIdentity?
    /// Accept any chain. Never a default; the connection reports `tlsVerified == false` so the UI can say so.
    public var skipVerification: Bool

    public init(serverName: String? = nil, anchorCertificates: [Data] = [], clientIdentity: TLSClientIdentity? = nil, skipVerification: Bool = false) {
        self.serverName = serverName; self.anchorCertificates = anchorCertificates
        self.clientIdentity = clientIdentity; self.skipVerification = skipVerification
    }

    /// The certificates of a PEM CA bundle, as DER. Throws when the file holds none, or one that Security can't
    /// read, so a broken bundle can never silently fall back to system trust.
    public static func certificates(fromPEM data: Data) throws(TLSBundleError) -> [Data] {
        let ders = PEM.blocks(in: data).filter { $0.label == "CERTIFICATE" || $0.label == "TRUSTED CERTIFICATE" }.map(\.der)
        guard !ders.isEmpty else { throw .noCertificates }
        guard ders.allSatisfy({ SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else { throw .unreadableCertificate }
        return ders
    }

    /// The name sent as SNI and checked against the certificate.
    public func expectedName(for endpoint: RedisEndpoint) -> String? {
        if let serverName, !serverName.isEmpty { return serverName }
        if case .tcp(let host, _) = endpoint { return host }
        return nil
    }

    // MARK: - Protocol options

    /// What `apply` puts into `sec_protocol_options`, as plain values (the options object has no getters).
    public struct ProtocolSettings: Sendable, Equatable {
        public var minimumVersion: tls_protocol_version_t
        /// Nil for IP literals, which RFC 6066 forbids as SNI; the certificate is still matched against them.
        public var sniName: String?
        public var clientIdentity: TLSClientIdentity?
    }

    public func protocolSettings(for endpoint: RedisEndpoint) -> ProtocolSettings {
        let name = expectedName(for: endpoint)
        let sni = name.flatMap { IPv4Address($0) == nil && IPv6Address($0) == nil ? $0 : nil }
        return ProtocolSettings(minimumVersion: Self.minimumVersion, sniName: sni, clientIdentity: clientIdentity)
    }

    /// Builds the TLS options for `endpoint`. The verify block runs on `queue`; it hands any refusal to `rejected`
    /// before failing the handshake, since Network itself only reports an OSStatus.
    public func makeOptions(for endpoint: RedisEndpoint, queue: DispatchQueue, rejected: @escaping @Sendable (TLSTrustFailure) -> Void) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let settings = protocolSettings(for: endpoint)
        sec_protocol_options_set_min_tls_protocol_version(options, settings.minimumVersion)
        if let sni = settings.sniName { sec_protocol_options_set_tls_server_name(options, sni) }
        if let identity = settings.clientIdentity, let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        let name = expectedName(for: endpoint)
        sec_protocol_options_set_verify_block(
            options,
            { _, trust, complete in
                let failure = evaluate(sec_trust_copy_ref(trust).takeRetainedValue(), serverName: name)
                if let failure { rejected(failure) }
                complete(failure == nil)
            }, queue)
        return tls
    }

    // MARK: - Trust evaluation

    /// Nil when the server's chain is acceptable. The chain is checked first without a name, so an untrusted chain
    /// reports its issuer and a trusted chain for the wrong name reports the names it does cover. `date` pins the
    /// evaluation time and turns off revocation fetches, for deterministic tests.
    public func evaluate(_ trust: SecTrust, serverName: String?, at date: Date? = nil) -> TLSTrustFailure? {
        if skipVerification { return nil }
        if !anchorCertificates.isEmpty {
            // An anchor that fails to decode leaves fewer anchors, never the system roots.
            let anchors = anchorCertificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        if let date {
            SecTrustSetVerifyDate(trust, date as CFDate)
            SecTrustSetNetworkFetchAllowed(trust, false)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
        guard SecTrustEvaluateWithError(trust, nil) else { return .untrusted(issuer: Self.issuer(of: trust), customCA: !anchorCertificates.isEmpty) }
        guard let serverName, !serverName.isEmpty else { return .noServerName }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, serverName as CFString))
        guard SecTrustEvaluateWithError(trust, nil) else {
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            return .hostnameMismatch(expected: serverName, certificateNames: leaf.map(Self.names) ?? [])
        }
        return nil
    }

    /// Who issued the top of the chain that was built: the root's own name when it is self-signed, else the
    /// issuer named by the last certificate the server sent.
    static func issuer(of trust: SecTrust) -> String {
        guard let top = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.last else { return "unknown issuer" }
        let selfIssued = SecCertificateCopyNormalizedIssuerSequence(top).map { $0 as Data } == SecCertificateCopyNormalizedSubjectSequence(top).map { $0 as Data }
        if selfIssued, let subject = SecCertificateCopySubjectSummary(top) { return sanitized(subject as String) }
        let fields = section(top, kSecOIDX509V1IssuerName)
        let name = fields.first { $0.label == "2.5.4.3" } ?? fields.first { $0.label == "2.5.4.10" }
        return name.map { sanitized($0.value) } ?? "unknown issuer"
    }

    /// DNS and IP subject alternative names, or the common name when there are none (at most 16).
    static func names(of certificate: SecCertificate) -> [String] {
        var names = section(certificate, kSecOIDSubjectAltName).filter { $0.label == "DNS Name" || $0.label == "IP Address" }.map(\.value)
        if names.isEmpty {
            var common: CFString?
            if SecCertificateCopyCommonName(certificate, &common) == errSecSuccess, let common { names = [common as String] }
        }
        return names.prefix(16).map(sanitized)
    }

    /// The string entries of one certificate section (`SecCertificateCopyValues`), as (label, value) pairs.
    private static func section(_ certificate: SecCertificate, _ oid: CFString) -> [(label: String, value: String)] {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
            let entry = values[oid as String] as? [String: Any], let items = entry[kSecPropertyKeyValue as String] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let label = item[kSecPropertyKeyLabel as String] as? String, let value = item[kSecPropertyKeyValue as String] as? String else { return nil }
            return (label, value)
        }
    }

    /// Peer-supplied text made safe to show: control characters dropped, at most 128 characters.
    static func sanitized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(128))
        return String(scalars)
    }
}

public enum TLSBundleError: Error, Equatable, Sendable {
    /// The file has no `CERTIFICATE` block.
    case noCertificates
    case unreadableCertificate
}

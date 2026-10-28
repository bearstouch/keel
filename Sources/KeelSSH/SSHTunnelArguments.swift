import Foundation

/// Why a tunnel's ssh arguments can't be built. Nothing is launched (FR-CN05, INT-06).
public enum SSHTunnelArgumentError: Error, Equatable, Sendable {
    /// Empty, starting with `-` (ssh would read it as an option, e.g. `-oProxyCommand=…`), or holding whitespace,
    /// control characters or characters no hostname or alias uses.
    case invalidDestination
    case invalidUser
    case invalidIdentityFile
    case invalidPort
    /// The Redis host as seen from the SSH server: a hostname, IPv4 or IPv6 literal.
    case invalidRedisHost
    case invalidRedisPort
}

/// What one tunnel connects through and to. Built from a saved SSH host or an inline destination; the Redis host and
/// port are resolved on the SSH server's side (FR-CN05).
public struct SSHTunnelConfiguration: Hashable, Sendable {
    public var destination: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var redisHost: String
    public var redisPort: UInt16

    public init(destination: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil, redisHost: String, redisPort: UInt16) {
        self.destination = destination; self.user = user; self.port = port; self.identityFile = identityFile
        self.redisHost = redisHost; self.redisPort = redisPort
    }

    public init(host: SavedHost, redisHost: String, redisPort: UInt16) {
        self.init(destination: host.destination, user: host.user, port: host.port, identityFile: host.identityFile, redisHost: redisHost, redisPort: redisPort)
    }
}

/// The `/usr/bin/ssh` argument array for a tunnel (02 Architecture → SSH tunnels). Built as an array, never through a
/// shell; every option is fixed here, user text only ever fills an option's value or the destination after `--`, and
/// no trust-bypass option (`StrictHostKeyChecking`, `UserKnownHostsFile`, `ProxyCommand`, …) is ever added.
public enum SSHTunnelArguments {
    public static let executable = "/usr/bin/ssh"

    /// Options that would weaken or bypass host-key trust or run a command. Never emitted; tests assert their absence.
    public static let forbiddenOptions = [
        "StrictHostKeyChecking", "UserKnownHostsFile", "GlobalKnownHostsFile", "KnownHostsCommand", "CheckHostIP", "ProxyCommand", "LocalCommand",
        "PermitLocalCommand", "UpdateHostKeys", "VerifyHostKeyDNS"
    ]

    public static func arguments(for configuration: SSHTunnelConfiguration, socketPath: String) throws(SSHTunnelArgumentError) -> [String] {
        let destination = try validatedDestination(configuration.destination)
        let host = try forwardHost(configuration.redisHost)
        guard configuration.redisPort > 0 else { throw .invalidRedisPort }
        // Command-line options win over ssh_config. A `ControlMaster`/`ControlPersist` or `ForkAfterAuthentication`
        // from the user's config would hand the forward to a background ssh that Keel can't signal or clean up.
        var arguments = [
            "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "StreamLocalBindUnlink=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
            "-L", "\(socketPath):\(host):\(configuration.redisPort)"
        ]
        if let port = configuration.port {
            guard (1...65_535).contains(port) else { throw .invalidPort }
            arguments += ["-p", String(port)]
        }
        if let user = configuration.user {
            // ssh takes the next argument as `-l`'s value, but a leading `-` is never a real user name.
            guard !user.isEmpty, !user.hasPrefix("-"), !hasUnsafeCharacters(user, allowSpaces: false) else { throw .invalidUser }
            arguments += ["-l", user]
        }
        if let identity = configuration.identityFile {
            guard !identity.isEmpty, !identity.hasPrefix("-"), !hasUnsafeCharacters(identity, allowSpaces: true) else { throw .invalidIdentityFile }
            arguments += ["-i", identity]
        }
        // `--` ends option parsing, so even a destination that slipped past validation is never read as an option.
        return arguments + ["--", destination]
    }

    /// Hostnames, IP literals, ssh_config aliases and `user@host`. A leading `-` is rejected outright.
    static func validatedDestination(_ destination: String) throws(SSHTunnelArgumentError) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]%@")
        guard !destination.isEmpty, !destination.hasPrefix("-"), destination.unicodeScalars.allSatisfy(allowed.contains) else { throw .invalidDestination }
        return destination
    }

    /// The host part of `-L <socket>:<host>:<port>`. ssh splits that spec on `:`, so IPv6 literals go in brackets.
    static func forwardHost(_ host: String) throws(SSHTunnelArgumentError) -> String {
        let name = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let ipv6 = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        var bare = host
        if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.contains(":") {
            guard bare.unicodeScalars.allSatisfy(ipv6.contains), !bare.hasSuffix("%") else { throw .invalidRedisHost }
            return "[\(bare)]"
        }
        guard !bare.isEmpty, !bare.hasPrefix("-"), bare == host, bare.unicodeScalars.allSatisfy(name.contains) else { throw .invalidRedisHost }
        return bare
    }

    private static func hasUnsafeCharacters(_ text: String, allowSpaces: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar.value == 0x7F || (!allowSpaces && scalar.properties.isWhitespace)
        }
    }
}

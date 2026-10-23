import Foundation

extension HostLibrary {
    /// The saved-password lookup for one tunnel launch through `host` (FR-CN06, KEEL-010), for
    /// `TunnelManager.acquire(savedPassword:)`. It is bound to the host's connection revision as it is now: if the
    /// destination, user, port or key changes meanwhile, the library has already removed the password and this
    /// returns nil, so a password is never offered to a different server. Nil when the host has no saved password.
    public nonisolated func savedPassword(for host: SavedHost, gate: any UserPresenceGate) -> (@Sendable () async -> Data?)? {
        guard host.savedPassword != nil else { return nil }
        let id = host.id, revision = host.connectionRevision
        return { [self] in await self.password(hostID: id, connectionRevision: revision, gate: gate) }
    }
}

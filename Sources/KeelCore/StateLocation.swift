import Foundation

/// Where this launch keeps its state (MAC-12): `--state-directory` wins, a fixture launch gets a fresh temporary
/// folder, and otherwise `~/Library/Application Support/<identity>`. The folder is created owner-only (0700).
public enum StateLocation {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notADirectory(String)
        case symlink(String)
        case notOwned(String)

        public var description: String {
            switch self {
            case .notADirectory(let path): return "State location \(path) exists and is not a folder."
            case .symlink(let path): return "State location \(path) is a symbolic link; Keel only uses real folders."
            case .notOwned(let path): return "State location \(path) belongs to another user."
            }
        }
    }

    public static func resolve(arguments: LaunchArguments, identity: AppInstanceIdentity, applicationSupport: URL, temporary: URL) -> URL {
        if let directory = arguments.stateDirectory { return directory }
        // A fresh folder per fixture launch, so demo runs never see each other's (or the real) state.
        if arguments.fixture { return temporary.appendingPathComponent("keel-fixture-\(UUID().uuidString)", isDirectory: true) }
        return applicationSupport.appendingPathComponent(identity.identifier, isDirectory: true)
    }

    /// Creates the folder (and missing parents) with mode 0700. A symlink, a file or a folder owned by someone else
    /// at the path is refused rather than used, so state never lands somewhere the user didn't choose; an existing
    /// folder of ours is tightened to 0700 (MAC-12).
    @discardableResult
    public static func prepare(_ directory: URL, fileManager: FileManager = .default) throws -> URL {
        let path = directory.path
        // `attributesOfItem` doesn't follow symlinks, so a link reports its own type. `createDirectory` would "succeed"
        // on a link to a folder, so it only runs when nothing is there, and the result is checked again afterwards
        // (another user may have planted something in a shared folder such as /tmp between the two calls).
        if (try? fileManager.attributesOfItem(atPath: path)) == nil {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        // A link could point anywhere (another user's folder, a synced volume); following it would write there.
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.symlink(path) }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.notADirectory(path) }
        // A folder pre-created by another account (e.g. `/tmp/x`) would let that account read or swap our state.
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw Failure.notOwned(path) }
        if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 { try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        return directory
    }
}

import Foundation

/// Where the bundled `keel-askpass` lives (MAC-08): `Contents/Helpers` of the installed app, or beside the binary in a
/// SwiftPM build (`swift build` builds it; `swift run Keel` alone doesn't). Nil when missing or not executable: tunnels
/// then run without askpass, so a saved password or a prompt fails closed in ssh instead of being guessed.
public enum AskpassHelperLocation {
    public static func find(executable: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let folder = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            folder.deletingLastPathComponent().appendingPathComponent("Helpers").appendingPathComponent(AskpassBroker.helperName),
            folder.appendingPathComponent(AskpassBroker.helperName)
        ]
        return candidates.map(\.path).first(where: isExecutable)
    }
}

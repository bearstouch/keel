import Foundation

/// What the ssh_config files a tunnel's ssh reads contain, found by reading them (and their `Include`s) without running
/// anything. `ssh -G` evaluates `Match exec`, so the launcher asks this first: a config with no forward needs no `ssh -G`,
/// and one whose `Match` lines run commands is never run an extra time for the check.
public struct SSHConfigScan: Equatable, Sendable {
    /// Some file sets `LocalForward`, `RemoteForward` or `DynamicForward`, in any block.
    public var forwards: Bool
    /// Some `Match` line has an `exec` criterion (negated or not).
    public var matchExec: Bool
    /// Every file was read and every `Include` resolved; false when one couldn't be, or the depth or file limit ran out.
    public var complete: Bool

    public init(forwards: Bool = false, matchExec: Bool = false, complete: Bool = true) {
        self.forwards = forwards; self.matchExec = matchExec; self.complete = complete
    }

    /// ssh's own include depth limit; the file count bounds a glob that matches a whole folder.
    static let depthLimit = 16
    static let fileLimit = 256

    /// Scans the files ssh reads for `arguments`: the `-F` file alone (nothing for `-F none`), otherwise `~/.ssh/config`
    /// and `/etc/ssh/ssh_config`. Relative includes resolve in `~/.ssh` for user files and `/etc/ssh` for the system file,
    /// as ssh does. `read` returns nil for a missing file; `glob` returns nil when a pattern can't be expanded.
    public static func scan(
        arguments: [String], home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        read: (String) throws -> Data? = { try SSHConfigDiscovery.readConfig(URL(fileURLWithPath: $0)) }, glob: (String) -> [String]? = SSHConfigScan.expand
    ) -> SSHConfigScan {
        var result = SSHConfigScan(), files = 0, visiting = Set<String>()
        let userBase = home + "/.ssh"

        func visit(_ path: String, base: String, depth: Int, required: Bool) {
            guard depth <= depthLimit, files < fileLimit else { result.complete = false; return }
            // A cycle is ssh's error to report; the files on it were already scanned.
            guard visiting.insert(path).inserted else { return }
            defer { visiting.remove(path) }
            files += 1
            let data: Data?
            do { data = try read(path) } catch { result.complete = false; return }
            guard let data else { if required { result.complete = false }; return }
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let words = SSHConfigDiscovery.tokens(String(line))
                guard let keyword = words.first?.lowercased() else { continue }
                switch keyword {
                case "localforward", "remoteforward", "dynamicforward": result.forwards = true
                case "match": if words.dropFirst().contains(where: { $0.lowercased().trimmingPrefix("!") == "exec" }) { result.matchExec = true }
                case "include":
                    for pattern in words.dropFirst() {
                        // ssh expands %-tokens and ${VAR} here; Keel can't tell what they resolve to.
                        guard !pattern.contains("%"), !pattern.contains("${") else { result.complete = false; continue }
                        let absolute = pattern == "~" || pattern.hasPrefix("~/") ? home + pattern.dropFirst() : pattern.hasPrefix("/") ? pattern : base + "/" + pattern
                        guard let matches = glob(absolute) else { result.complete = false; continue }
                        for match in matches { visit(match, base: base, depth: depth + 1, required: false) }
                    }
                default: continue
                }
            }
        }

        if let file = configFileArgument(arguments) {
            if file != "none" { visit(file, base: userBase, depth: 0, required: true) }
        } else {
            visit(userBase + "/config", base: userBase, depth: 0, required: false)
            visit("/etc/ssh/ssh_config", base: "/etc/ssh", depth: 0, required: false)
        }
        return result
    }

    /// The value of `-F` before the destination (`--`), as ssh reads it: `-F file` or `-Ffile`.
    static func configFileArgument(_ arguments: [String]) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex, arguments[index] != "--" {
            let argument = arguments[index]
            if argument == "-F" { return index + 1 < arguments.endIndex ? arguments[index + 1] : nil }
            if argument.hasPrefix("-F") { return String(argument.dropFirst(2)) }
            index += 1
        }
        return nil
    }

    /// `glob(3)` without tilde or brace expansion: no match is an empty list, any other failure nil.
    public static func expand(_ pattern: String) -> [String]? {
        var found = glob_t()
        defer { globfree(&found) }
        switch Darwin.glob(pattern, 0, nil, &found) {
        case 0: return (0..<Int(found.gl_pathc)).compactMap { found.gl_pathv[$0].flatMap { String(validatingCString: $0) } }
        case GLOB_NOMATCH: return []
        default: return nil
        }
    }
}

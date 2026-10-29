import Foundation

/// Command-line options the app understands. Parsing is strict for Keel's own `--` flags so a typo never
/// silently launches against the wrong state, but it tolerates the arguments macOS and Xcode add themselves.
public struct LaunchArguments: Equatable, Sendable {
    /// Absolute folder that replaces Application Support for this launch.
    public var stateDirectory: URL?
    /// Isolated demo state in a fresh temporary folder.
    public var fixture = false

    public init(stateDirectory: URL? = nil, fixture: Bool = false) { self.stateDirectory = stateDirectory; self.fixture = fixture }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownArgument(String)
        case missingValue(String)
        case relativeStateDirectory(String)
        /// One of Keel's flags written with a single dash; `suggestion` is the flag meant.
        case singleDash(String, suggestion: String)

        public var description: String {
            switch self {
            case .unknownArgument(let argument): return "Unknown argument \(argument)."
            case .singleDash(let argument, let suggestion): return "Unknown argument \(argument). Did you mean \(suggestion)?"
            case .missingValue(let flag): return "\(flag) needs a value."
            case .relativeStateDirectory(let path): return "--state-directory must be an absolute path, got \(path)."
            }
        }
    }

    /// Parses the arguments after the executable path (`CommandLine.arguments.dropFirst()`).
    public static func parse<S: Sequence>(_ arguments: S) throws -> LaunchArguments where S.Element == String {
        var result = LaunchArguments()
        var remaining = Array(arguments)[...]
        while let argument = remaining.popFirst() {
            // `--state-directory=/path` and `--state-directory /path` are both accepted.
            let (flag, inline) = split(argument)
            switch flag {
            case "--state-directory":
                // A following `--flag` is a forgotten value, not a folder name.
                guard let path = inline ?? remaining.popFirst(), !path.isEmpty, !path.hasPrefix("--") else { throw ParseError.missingValue(flag) }
                // Relative paths (and `~`, which the shell didn't expand) would depend on the launch's working directory.
                guard path.hasPrefix("/") else { throw ParseError.relativeStateDirectory(path) }
                result.stateDirectory = URL(fileURLWithPath: (path as NSString).standardizingPath, isDirectory: true)
            // Switches take no value; `--fixture=yes` is refused rather than guessed at.
            case "--fixture" where inline == nil: result.fixture = true
            default:
                if flag.hasPrefix("--") { throw ParseError.unknownArgument(argument) }
                // LaunchServices adds `-psn_0_…`; AppKit/Xcode pass `-Key value` user-default overrides
                // (`-NSDocumentRevisionsDebugMode YES`). Those belong to the system, not to Keel, so they're skipped
                // (with their value) instead of failing a Finder or Xcode launch. A following `--flag` is never eaten as
                // that value, so `-Key --fixture` can't silently drop Keel's own flag.
                if flag.hasPrefix("-psn_") { continue }
                // `-fixture` or `-state-directory /tmp/demo` is a typo of Keel's own flag, not a user default: skipping it
                // would launch against the real state and swallow the path.
                if let flag = singleDashTypo(argument) { throw ParseError.singleDash(argument, suggestion: flag) }
                if flag.hasPrefix("-"), flag.count > 1 {
                    if let next = remaining.first, !next.hasPrefix("--"), singleDashTypo(next) == nil { remaining.removeFirst() }
                    continue
                }
                throw ParseError.unknownArgument(argument)
            }
        }
        return result
    }

    /// Keel's own flags, for spotting single-dash typos.
    static let flags = ["--state-directory", "--fixture"]

    /// The flag `argument` (`-fixture`, `-State-Directory=/x`) misspells with a single dash, or nil.
    private static func singleDashTypo(_ argument: String) -> String? {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return nil }
        let name = argument.dropFirst().prefix { $0 != "=" }.lowercased()
        return flags.first { $0.dropFirst(2) == name }
    }

    /// Splits `--flag=value` into its parts; anything else is returned whole with no inline value.
    private static func split(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }
}

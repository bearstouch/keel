import Darwin
import Foundation

/// NFR-PF01 evidence: with `KEEL_LAUNCH_METRICS=/abs/file.json` in the environment, the first sidebar render writes
/// the seconds since the process started to that file, once, for `scripts/bench-browser.py`. Without the variable it
/// does nothing. The file holds a single number and no server data.
public enum LaunchMetrics {
    public static let environmentKey = "KEEL_LAUNCH_METRICS"

    nonisolated(unsafe) private static var recorded = false
    private static let lock = NSLock()

    /// Called by the sidebar when it first appears; later calls (more windows) are ignored.
    public static func firstSidebarRender(environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) {
        guard let path = environment[environmentKey], path.hasPrefix("/") else { return }
        let first = lock.withLock { () -> Bool in
            guard !recorded else { return false }
            recorded = true
            return true
        }
        guard first, let started = processStart() else { return }
        let report = ["first_sidebar_render_seconds": now.timeIntervalSince(started)]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    /// When the kernel started this process, so time spent before `main` (dyld, static initializers) counts too.
    static func processStart() -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

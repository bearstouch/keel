import Foundation

/// Appends one JSON line per measurement to `KEEL_BENCH_OUTPUT` when it is set, so `scripts/bench-browser.py` can
/// collect the evidence; without it (a plain `swift test`) nothing is written. Metric names are the script's keys.
/// The same recorder as `KeelCoreTests`' (test targets can't share sources).
enum BenchmarkRecorder {
    static func record(_ metric: String, _ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        write(metric, value: Double(seconds) + Double(attoseconds) / 1e18, unit: "s")
    }

    static func record(_ metric: String, bytes: Double) { write(metric, value: bytes, unit: "bytes") }

    private static let lock = NSLock()

    private static func write(_ metric: String, value: Double, unit: String) {
        guard let path = ProcessInfo.processInfo.environment["KEEL_BENCH_OUTPUT"], !path.isEmpty else { return }
        guard let line = try? JSONSerialization.data(withJSONObject: ["metric": metric, "value": value, "unit": unit], options: [.sortedKeys]) else { return }
        lock.withLock {
            // The script creates the file; a missing one is created here so a hand-run test can still record.
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        }
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for:)` that only calls into the runtime when it will suspend. On macOS 26.6 a sleep that ends
    /// without suspending (a zero duration, or a task cancelled before it sleeps) aborts the concurrency runtime
    /// ("freed pointer was not the last allocation"); this checks those cases itself.
    public static func suspendingSleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}

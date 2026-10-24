import AppKit
import Combine
import KeelCore

/// The refresh button's menu (FR-SI03): off by default, or every 2, 5, 10 or 30 seconds.
public enum InfoRefreshInterval: Int, CaseIterable, Sendable, Identifiable {
    case off = 0, two = 2, five = 5, ten = 10, thirty = 30

    public var id: Int { rawValue }
    public var title: String { self == .off ? "Off" : "Every \(rawValue) s" }
    public var duration: Duration? { self == .off ? nil : .seconds(rawValue) }
}

/// Info mode of one tab (FR-SI01 – FR-SI05): the last `INFO` reply, its overview and the refresh. `INFO` goes through the
/// data path like every command; auto-refresh runs only while the mode is on screen (`appeared` / `disappeared`).
@MainActor
public final class InfoModel: ObservableObject {
    /// Sleeps between auto-refreshes; injected so tests drive the interval without waiting.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published public private(set) var report: InfoReport?
    @Published public private(set) var overview: InfoOverview?
    /// Why the last refresh didn't give a report ("INFO isn't permitted…", a timeout); the previous report stays shown.
    @Published public private(set) var notice: String?
    @Published public private(set) var isLoading = false
    @Published public var interval = InfoRefreshInterval.off { didSet { if interval != oldValue { schedule() } } }
    /// "Show all INFO fields" is open; `rawQuery` filters its Raw view.
    @Published public var showsAll = false
    @Published public var rawQuery = ""
    public private(set) var isVisible = false
    /// Panes on screen: a tab moved between windows can appear in the new one before it disappears from the old.
    private var shown = 0

    private let service: DataCommandService
    private let context: DataContext
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private var loop: Task<Void, Never>?
    /// Bumped by every refresh, so a reply that lands after a newer one started is dropped.
    private var generation = 0
    /// The window showing the mode, for ⌘R (sent to the key window).
    weak var window: NSWindow?
    private var observer: NSObjectProtocol?
    /// Browse on a database row: the tab switches to Browser mode on it.
    var onBrowse: ((Int) -> Void)?

    public init(
        service: DataCommandService, context: DataContext, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.service = service; self.context = context; self.now = now; self.sleep = sleep
        observer = NotificationCenter.default.addObserver(forName: KeyListCommands.refreshNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.isVisible, window != nil, self.window === window else { return }
                Task { await self.refresh() }
            }
        }
    }

    isolated deinit {
        loop?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The mode came on screen: a fresh `INFO` at once, then the interval's refreshes.
    public func appeared() {
        shown += 1
        guard !isVisible else { return }
        isVisible = true
        schedule()
        Task { await refresh() }
    }

    /// The mode left the screen (another mode or tab, the window closed): no more `INFO` until it is back (AC2).
    public func disappeared() {
        shown = max(shown - 1, 0)
        guard shown == 0 else { return }
        isVisible = false
        loop?.cancel(); loop = nil
    }

    /// The tab disconnected.
    public func shutdown() { shown = 1; disappeared(); onBrowse = nil }

    public func browse(_ database: Int) { onBrowse?(database) }

    /// ⌘R and the refresh button: `INFO` once. A failure keeps the previous report and says why.
    public func refresh() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        let result = await InfoReport.load(service: service, context: context)
        guard mine == generation else { return }
        switch result {
        case .success(let report):
            show(report); notice = nil
        case .failure(let error) where error.code == "PERMISSION_DENIED":
            // An ACL without INFO: every section is unavailable (FR-SI05), and the reason shows.
            show(InfoReport(text: "")); notice = "This user isn't permitted to run INFO, so server details are unavailable."
        case .failure(let error):
            // A timeout or a lost connection: the last report stays, with why it isn't fresh.
            notice = error.message
        }
    }

    private func show(_ report: InfoReport) {
        self.report = report
        overview = InfoOverview(report: report, now: now())
    }

    /// One loop per visible stretch with an interval: sleep, refresh, repeat. Each refresh finishes before the next sleep.
    private func schedule() {
        loop?.cancel(); loop = nil
        guard isVisible, let duration = interval.duration else { return }
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(duration) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
}

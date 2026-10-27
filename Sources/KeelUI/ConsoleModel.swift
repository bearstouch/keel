import AppKit
import Combine
import KeelCore

/// Console history per profile, in memory for the app's lifetime (FR-CO04): every console of a profile shares it, so it
/// survives switching and closing tabs, never a relaunch.
@MainActor
public final class ConsoleHistoryBook {
    private var histories: [UUID: ConsoleHistory] = [:]

    public init() {}

    public subscript(profile: UUID) -> ConsoleHistory { histories[profile] ?? ConsoleHistory() }

    public func add(_ line: String, profile: UUID) { histories[profile, default: ConsoleHistory()].add(line) }
}

/// ⌥⌘K and ⌘. from the menus, posted with the key window; the console shown there answers.
public enum ConsoleCommands {
    public static let clearNotification = Notification.Name("com.bearstouch.keel.clearConsole")
    public static let stopNotification = Notification.Name("com.bearstouch.keel.stopConsoleCommand")
}

/// A plain yes before a console command runs: admin commands and KEYS (FR-CO06), an O(N) command on something large
/// (FR-SF08). The typed ones (FLUSHDB, FLUSHALL, multi-key DEL) use the shared `TypedConfirmationSheet`.
public struct ConsoleGoAhead: Identifiable, Equatable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var arguments: [Data]
    public var database: Int
}

/// One tab's console (FR-CO01 – FR-CO10): the scrollback, the prompt, history, completion and the command or stream
/// running. Lines go through `ConsoleSession`, so every command takes the data path and the safety policy. The output
/// lives only in memory and the view (FR-CO09).
@MainActor
public final class ConsoleModel: ObservableObject {
    public enum State: Equatable {
        case idle
        /// A command is in flight; Stop closes its connection (a blocking one may wait for good).
        case running
        /// MONITOR / SUBSCRIBE output is arriving; Stop ends it.
        case streaming
    }

    public let console: ConsoleSession
    public let profileID: UUID
    @Published public private(set) var buffer = ConsoleBuffer() { didSet { textView?.show(buffer) } }
    @Published public private(set) var prompt: String
    @Published public private(set) var state = State.idle { didSet { textView?.setInputActive(state == .idle, prompt: prompt) } }
    @Published public var typedConfirmation: TypedConfirmationModel?
    @Published public var goAhead: ConsoleGoAhead?
    /// Completion names: the session's catalog (the server's `COMMAND DOCS` over the bundled one) once `start()` ran.
    public private(set) var catalog = CommandCatalog.bundled
    public private(set) var cursor = ConsoleHistoryCursor()
    /// ⌃R: the query and the history entry it found, while searching.
    public private(set) var search: (query: String, match: Int?)?

    private let histories: ConsoleHistoryBook
    private var draining: Task<Void, Never>?
    private let drainInterval: Duration
    /// The typed confirmation's command ran (its sheet closed by confirming, not by Cancel).
    private var confirmedTyped = false
    private var observers: [NSObjectProtocol] = []
    /// The AppKit view, made on first use (`scrollView`).
    private(set) var textView: ConsoleTextView?

    public init(console: ConsoleSession, profileID: UUID, histories: ConsoleHistoryBook, prompt: String, drainInterval: Duration = .milliseconds(50)) {
        self.console = console; self.profileID = profileID; self.histories = histories; self.prompt = prompt; self.drainInterval = drainInterval
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: ConsoleCommands.clearNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { if let self, self.isShown(in: window) { self.clear() } }
            })
        observers.append(
            center.addObserver(forName: ConsoleCommands.stopNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { if let self, self.isShown(in: window) { Task { await self.stop() } } }
            })
    }

    isolated deinit {
        draining?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The console's scroll view with its text view, made once.
    public lazy var scrollView: NSScrollView = {
        let view = ConsoleTextView.makeScrollView(model: self)
        textView = view.documentView as? ConsoleTextView
        textView?.show(buffer)
        textView?.setInputActive(state == .idle, prompt: prompt)
        return view
    }()

    private func isShown(in window: NSWindow?) -> Bool { window != nil && textView?.window === window }

    public var history: ConsoleHistory { histories[profileID] }

    /// Loads the completion catalog; the session refreshed it from the server when it connected.
    public func start() async { catalog = await console.service.catalog }

    /// The tab disconnected or closed: the drain stops and the console's connections close.
    public func shutdown() async {
        draining?.cancel(); draining = nil
        await console.close()
    }

    // MARK: - Running

    /// Return: echoes the line (credentials masked, FR-CO10), adds it to history and runs it. Ignored while something runs.
    public func submit(_ line: String) async {
        guard state == .idle else { return }
        cursor.reset(); search = nil
        // redis-cli's own `clear`.
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "clear" { clear(); return }
        let arguments: [Data]
        do throws(ConsoleParseError) { arguments = try ConsoleTokenizer.arguments(line) } catch {
            // Nothing is sent for a line that can't be split (FR-CO02).
            echo(ConsoleMasking.displayUnparsed(line))
            buffer.append(ConsoleLine("(error) " + error.message, kind: .error))
            return
        }
        echo(ConsoleMasking.display(line, arguments: arguments))
        guard !arguments.isEmpty else { return }
        await run(arguments, confirmation: nil)
    }

    private func echo(_ display: String) {
        buffer.append(ConsoleLine(display, kind: .command(prompt: prompt)))
        histories.add(display, profile: profileID)
    }

    private func run(_ arguments: [Data], confirmation: CommandConfirmation?) async {
        state = .running
        let outcome = await console.run(arguments, confirmation: confirmation)
        let database = await console.database
        prompt = await console.prompt
        switch outcome {
        case .printed(let lines):
            buffer.append(contentsOf: lines)
            state = .idle
        case .streaming(let lines):
            buffer.append(contentsOf: lines)
            state = .streaming
            drain()
        case .needsConfirmation(let request, let warning):
            state = .idle
            if let warning { buffer.append(ConsoleLine(warning.message, kind: .notice)) }
            let yes = CommandConfirmation(scope: .command(arguments), database: database)
            if let typed = TypedConfirmation(request, profile: console.profile, database: database) {
                confirmedTyped = false
                typedConfirmation = TypedConfirmationModel(typed) { [weak self] in
                    self?.confirmedTyped = true
                    // The sheet closes at once; the reply prints in the console.
                    Task { await self?.run(arguments, confirmation: yes) }
                    return nil
                }
            } else {
                let title: String
                switch request.operation {
                case .keys: title = "Run KEYS?"
                case .admin(let command): title = "Run \(command)?"
                default: title = "Run this command?"
                }
                goAhead = ConsoleGoAhead(title: title, message: request.message, arguments: arguments, database: database)
            }
        case .needsGoAhead(let warning):
            state = .idle
            goAhead = ConsoleGoAhead(title: "Run anyway?", message: warning.message, arguments: arguments, database: database)
        }
    }

    /// The plain confirmation's Run.
    public func confirmGoAhead() async {
        guard let request = goAhead else { return }
        goAhead = nil
        await run(request.arguments, confirmation: CommandConfirmation(scope: .command(request.arguments), database: request.database))
    }

    /// The plain confirmation's Cancel.
    public func cancelGoAhead() {
        guard goAhead != nil else { return }
        goAhead = nil
        buffer.append(ConsoleLine("Not sent.", kind: .notice))
    }

    /// The typed sheet closed; by Cancel unless its action ran.
    public func dismissTypedConfirmation() {
        guard typedConfirmation != nil else { return }
        typedConfirmation = nil
        if !confirmedTyped { buffer.append(ConsoleLine("Not sent.", kind: .notice)) }
    }

    /// Stop (⌘.): ends a stream, or cancels the command in flight by closing its connection (FR-CO07).
    public func stop() async {
        switch state {
        case .idle: return
        case .streaming: await console.stopStream()
        case .running: await console.cancel()
        }
    }

    /// Moves a stream's lines into the scrollback every `drainInterval`, so a busy MONITOR updates the view in batches.
    private func drain() {
        draining?.cancel()
        draining = Task { [weak self, drainInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: drainInterval)
                guard let self else { return }
                let drained = await self.console.drainStream()
                if drained.dropped > 0 {
                    self.buffer.append(ConsoleLine("… \(KeyIndexFooter.grouped(drained.dropped)) lines skipped while the console caught up", kind: .notice))
                }
                self.buffer.append(contentsOf: drained.lines)
                if drained.ended {
                    self.buffer.append(ConsoleLine("Stopped.", kind: .notice))
                    self.draining = nil; self.state = .idle
                    return
                }
            }
        }
    }

    /// ⌥⌘K / ⌃L / `clear`.
    public func clear() { buffer.clear() }

    /// Copy Reply (FR-CO09): the output lines of one command, without its echo.
    public func replyText(_ reply: Int) -> String {
        buffer.lines.filter { line in
            guard line.reply == reply else { return false }
            if case .command = line.kind { return false }
            return true
        }
        .map(\.text).joined(separator: "\n")
    }

    /// Copy All Output.
    public var allText: String { buffer.lines.map { line in if case .command(let prompt) = line.kind { prompt + line.text } else { line.text } }.joined(separator: "\n") }

    // MARK: - History and completion

    /// ↑: the older history entry, nil at the oldest.
    public func historyPrevious(current: String) -> String? { cursor.previous(in: history, current: current) }

    /// ↓: the newer entry, then the line that was being typed.
    public func historyNext() -> String? { cursor.next(in: history) }

    /// The line was edited by hand: ↑ starts from the newest entry again.
    public func lineEdited() { cursor.reset() }

    /// ⌃R: starts a reverse search, or finds the next older match of the same query. Returns the line to show.
    public func reverseSearch() -> String? {
        if let search {
            let match = history.search(search.query, before: search.match) ?? search.match
            self.search = (search.query, match)
        } else {
            search = ("", history.search(""))
        }
        return searchMatch
    }

    /// A character typed (or deleted) while searching: the newest entry with the new query.
    public func updateSearch(_ query: String) -> String? {
        guard search != nil else { return nil }
        search = (query, history.search(query))
        return searchMatch
    }

    private var searchMatch: String? { search?.match.map { history.entries[$0] } }

    /// Return, Escape or an arrow ends the search; the found line stays for editing.
    public func endSearch() { search = nil }

    public func completion(for line: String) -> ConsoleCompletion { ConsoleCompleter.complete(line, catalog: catalog) }

    public func hint(for line: String, completion: ConsoleCompletion, selected: Int) -> String {
        if let search { return "  (reverse-i-search: '\(search.query)')" }
        return ConsoleCompleter.hint(line, completion: completion, selected: selected, catalog: catalog)
    }
}

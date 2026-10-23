import Foundation
import KeelRESP

/// How the browser scans: page size, the loaded-key limit and the server-side filters (FR-KB02, FR-KB05, NFR-RS02).
public struct KeyIndexConfiguration: Sendable, Equatable {
    public static let defaultPageSize = 1_000
    public static let defaultLimit = 1_000_000
    public static let maximumLimit = 10_000_000
    /// SCAN's `COUNT` is only a hint, so a page can hold more keys than this; it also caps how much one Continue adds.
    public static let maximumPageSize = 100_000

    public var pageSize: Int
    /// Loaded keys at which scanning stops with a notice; Continue raises it by this much again, up to `maximumLimit`.
    public var limit: Int
    /// `MATCH` and `TYPE` for every page; a type SCAN can't express is checked per key (FR-KB05).
    public var filter: KeyFilter

    public init(pageSize: Int = defaultPageSize, limit: Int = defaultLimit, filter: KeyFilter = KeyFilter()) {
        self.pageSize = min(max(pageSize, 1), Self.maximumPageSize)
        self.limit = min(max(limit, 1), Self.maximumLimit)
        self.filter = filter
    }
}

/// A key's type as `TYPE` / `SCAN … TYPE` name it; `unknown` until fetched (KEEL-024 fills it for visible rows).
public enum KeyType: UInt8, Sendable, Equatable, CaseIterable {
    case unknown, string, hash, list, set, zset, stream, other
}

/// Per-key metadata kept beside the arena; deliberately tiny so a million keys stay inside NFR-RS01.
public struct KeyMetadata: Sendable, Equatable {
    public var type: KeyType
    /// The key was reported missing or changed elsewhere and is waiting for the next refresh (FR-KB12).
    public var isStale: Bool

    public init(type: KeyType = .unknown, isStale: Bool = false) { self.type = type; self.isStale = isStale }
}

/// Why a SCAN page didn't load. The keys already loaded and the cursor are kept, so Load more retries the same page.
public struct KeyIndexError: Error, Sendable, Equatable {
    /// The shared API code (`specs/05-api.md#errors`).
    public var code: String
    public var message: String

    public init(code: String, message: String) { self.code = code; self.message = message }
}

public enum KeyIndexPhase: Sendable, Equatable {
    /// Waiting for Load more (or Auto-page).
    case idle
    case scanning
    /// Auto-paging was paused from the ⋯ menu; Load more or Auto-page resumes.
    case paused
    /// The loaded-key limit was reached; Continue raises it (until `maximumLimit`).
    case limitReached
    /// The cursor came back to 0: "All keys loaded".
    case complete
    case failed(KeyIndexError)
}

public enum KeyPagingMode: Sendable, Equatable { case manual, auto }

public struct KeyIndexStatus: Sendable, Equatable {
    public var loadedCount: Int
    public var limit: Int
    public var phase: KeyIndexPhase
    public var mode: KeyPagingMode

    public init(loadedCount: Int, limit: Int, phase: KeyIndexPhase, mode: KeyPagingMode) {
        self.loadedCount = loadedCount; self.limit = limit; self.phase = phase; self.mode = mode
    }

    /// Continue is offered at the limit unless the limit is already the hard maximum.
    public var canContinue: Bool { phase == .limitReached && limit < KeyIndexConfiguration.maximumLimit }
}

/// The key list's footer: one quiet line, its trailing action shown as a link (FR-KB02, 08 Design).
public struct KeyIndexFooter: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case loadMore = "Load more", `continue` = "Continue", retry = "Retry"
    }

    /// "250,000 of 1.2M keys loaded", or "All keys loaded".
    public var summary: String
    /// "Paused", "Limit reached" or the scan error; nil when there is nothing to say.
    public var notice: String?
    public var action: Action?

    /// The whole line as shown and read by VoiceOver: "250,000 of 1.2M keys loaded · Load more".
    public var text: String { ([summary, notice, action?.rawValue] as [String?]).compactMap { $0 }.joined(separator: " · ") }

    /// `totalKeys` is the database's `DBSIZE` when known (KEEL-025); without it the line shows the loaded count only.
    public init(status: KeyIndexStatus, totalKeys: Int? = nil) {
        let loaded = Self.grouped(status.loadedCount)
        let keys = status.loadedCount == 1 && totalKeys == nil ? "key" : "keys"
        summary = totalKeys.map { "\(loaded) of \(Self.abbreviated($0)) \(keys) loaded" } ?? "\(loaded) \(keys) loaded"
        switch status.phase {
        case .complete: summary = "All keys loaded"; notice = nil; action = nil
        case .scanning: notice = nil; action = nil
        case .idle: notice = nil; action = .loadMore
        case .paused: notice = "Paused"; action = .loadMore
        case .limitReached: notice = "Limit reached"; action = status.canContinue ? .continue : nil
        case .failed(let error): notice = "Scan failed: \(error.message)"; action = .retry
        }
    }

    /// 250000 → "250,000". Fixed grouping so the footer reads the same in every locale, like the spec's examples.
    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    /// Totals of a million or more are shortened, rounding down so the total never reads larger than it is:
    /// 1,249,999 → "1.2M", 3,000,000 → "3M"; smaller totals are grouped in full.
    static func abbreviated(_ value: Int) -> String {
        for (scale, suffix) in [(1_000_000_000, "B"), (1_000_000, "M")] where value >= scale {
            let tenths = value / (scale / 10)
            return tenths % 10 == 0 ? "\(tenths / 10)\(suffix)" : "\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        return grouped(value)
    }
}

/// The browser's SCAN results for one database (02 Architecture → Key index). Keys live back to back in one byte
/// arena with an end-offset array and a parallel metadata array; an open-addressing table of indices deduplicates
/// keys SCAN returns more than once. Display strings are never stored: the UI derives them for visible rows only
/// (`KeyDisplay`). The namespace tree grows with every page and points into the same arena (FR-KB03).
///
/// Every page is one `SCAN` sent through `DataCommandService` from the `.browser` origin — never `KEYS` (FR-KB01).
public actor KeyIndex {
    public let service: DataCommandService
    public let context: DataContext
    public private(set) var configuration: KeyIndexConfiguration

    // Storage: key i is arena[(i == 0 ? 0 : ends[i - 1]) ..< ends[i]].
    private var arena = ContiguousArray<UInt8>()
    private var ends = ContiguousArray<Int>()
    private var metadata = ContiguousArray<KeyMetadata>()
    /// Open addressing with linear probing; a slot holds index + 1, 0 is empty. Capacity is a power of two.
    private var slots = ContiguousArray<UInt32>(repeating: 0, count: 1_024)
    private var tree: NamespaceTree
    /// Bumped on every new tree (separator change, restart) so folder IDs from the old one are refused.
    private var treeBuild = 0

    private var cursor = Data("0".utf8)
    private var started = false
    /// Keys of the last page that didn't fit under the limit, added first on Continue so no key between cursors is lost.
    private var overflow: [Data] = []
    private var limit: Int
    private var phase = KeyIndexPhase.idle
    private var mode = KeyPagingMode.manual
    private var inFlight = false
    private var pauseRequested = false
    /// Bumped by `restart`, so a page still in flight for the previous scan is dropped when it lands; the list reads it
    /// to notice a restart even when more keys than before are loaded by the time it reloads.
    public private(set) var generation = 0

    public init(
        service: DataCommandService, context: DataContext, configuration: KeyIndexConfiguration = KeyIndexConfiguration(), separator: NamespaceSeparator = .default
    ) {
        self.service = service; self.context = context; self.configuration = configuration; self.limit = configuration.limit
        tree = NamespaceTree(separator: separator)
    }

    // MARK: - Reading

    public var count: Int { ends.count }

    public var status: KeyIndexStatus { KeyIndexStatus(loadedCount: ends.count, limit: limit, phase: phase, mode: mode) }

    /// The key's original bytes, as every command must use them (FR-KB10).
    public func key(at index: Int) -> Data { Data(bytes(at: index)) }

    /// Keys for a visible range; the range is clamped to what is loaded.
    public func keys(in range: Range<Int>) -> [Data] {
        range.clamped(to: 0..<ends.count).map(key(at:))
    }

    public func metadata(at index: Int) -> KeyMetadata { metadata[index] }

    public func updateMetadata(at index: Int, _ update: @Sendable (inout KeyMetadata) -> Void) {
        guard metadata.indices.contains(index) else { return }
        update(&metadata[index])
    }

    /// Bytes the index holds in its buffers (capacity, not just use) — the figure NFR-RS01 budgets.
    public var storageBytes: Int {
        arena.capacity + ends.capacity * MemoryLayout<Int>.stride + metadata.capacity * MemoryLayout<KeyMetadata>.stride
            + slots.capacity * MemoryLayout<UInt32>.stride
    }

    /// Bytes the namespace tree holds in its buffers; NFR-RS01 budgets it with the index (< 200 MB for 1M keys).
    public var treeStorageBytes: Int { tree.storageBytes }

    /// Total bytes of the key names themselves.
    public var keyBytes: Int { arena.count }

    // MARK: - Namespace tree

    public var separator: NamespaceSeparator { tree.separator }

    /// Rebuilds the tree when the separator changes (AC2); folder IDs from the old tree are no longer valid.
    public func setSeparator(_ separator: NamespaceSeparator) {
        guard separator != tree.separator else { return }
        treeBuild += 1
        tree = NamespaceTree(separator: separator, build: treeBuild)
        withKeyBytes { tree.extend(with: $0) }
    }

    /// A folder's rows, sub-folders first, each group in byte order (expanding a node).
    public func namespaceChildren(of folder: NamespaceFolderID = .root) -> [NamespaceChild] {
        guard hasFolder(folder) else { return [] }
        return withKeyBytes { tree.children(of: folder.rawValue, $0) }
    }

    /// Names and counts for the rows in view; folders from an earlier tree and keys past the loaded range are skipped.
    /// `fullNames` gives keys their whole name (the flat view) instead of the last segment.
    public func namespaceEntries(_ children: some Sequence<NamespaceChild>, fullNames: Bool = false) -> [NamespaceEntry] {
        withKeyBytes { keys in
            children.compactMap { child in
                switch child {
                case .folder(let id) where hasFolder(id):
                    return NamespaceEntry(child: child, name: Data(tree.name(of: child, keys)), keyCount: Int(tree.folders[id.rawValue].keyCount))
                case .key(let index) where ends.indices.contains(index):
                    return NamespaceEntry(child: child, name: Data(fullNames ? keys[index] : tree.name(of: child, keys)), keyCount: 1, metadata: metadata[index])
                default: return nil
                }
            }
        }
    }

    /// The folders to expand to reveal a key, outermost first (root excluded); empty for a key past the loaded range.
    public func namespaceAncestors(ofKey index: Int) -> [NamespaceFolderID] {
        guard ends.indices.contains(index) else { return [] }
        return withKeyBytes { keys in tree.ancestors(of: index, keys).map { NamespaceFolderID(rawValue: $0, build: tree.build) } }
    }

    /// Loaded keys at or below a folder (the root counts every key).
    public func namespaceKeyCount(of folder: NamespaceFolderID) -> Int {
        hasFolder(folder) ? Int(tree.folders[folder.rawValue].keyCount) : 0
    }

    /// A folder's full path without a trailing separator ("a:b"), e.g. to filter by it.
    public func namespacePath(of folder: NamespaceFolderID) -> Data? {
        guard hasFolder(folder) else { return nil }
        return withKeyBytes { Data(tree.path(of: folder.rawValue, $0)) }
    }

    /// False for IDs from a tree that was since rebuilt or restarted: a stale ID must never resolve to another folder.
    private func hasFolder(_ folder: NamespaceFolderID) -> Bool {
        folder.rawValue == 0 || (folder.build == tree.build && tree.folders.indices.contains(folder.rawValue))
    }

    private func withKeyBytes<T: Sendable>(_ body: (KeyBytes) -> T) -> T {
        arena.withUnsafeBytes { arena in ends.withUnsafeBufferPointer { body(KeyBytes(arena: arena, ends: $0)) } }
    }

    // MARK: - Scanning

    /// Load more: exactly one SCAN iteration (FR-KB02). Does nothing while a page is in flight, once the scan is
    /// complete or at the limit, so a double click never sends a second SCAN for the same cursor.
    @discardableResult
    public func loadMore() async -> KeyIndexStatus {
        mode = .manual; pauseRequested = false
        let scanGeneration = generation
        _ = await scanPage()
        // A restart while the page was in flight owns the phase; only a finished page of this scan settles to idle.
        if scanGeneration == generation, !inFlight, phase == .scanning { phase = .idle }
        return status
    }

    /// Auto-page: keeps scanning until the cursor returns to 0, the limit is reached, `pause()` is called, a page
    /// fails or the calling task is cancelled. The UI calls it while the list is visible and cancels it when hidden.
    @discardableResult
    public func autoPage() async -> KeyIndexStatus {
        guard !inFlight else { mode = .auto; return status }
        mode = .auto; pauseRequested = false
        let scanGeneration = generation
        // Load more during the loop switches to manual, which ends the loop after the page in flight.
        while !Task.isCancelled, !pauseRequested, mode == .auto, await scanPage() {}
        // A restart during the loop owns the phase; otherwise a loop that stopped mid-scan is paused or idle.
        if scanGeneration == generation, !inFlight, phase == .scanning { phase = pauseRequested ? .paused : .idle }
        return status
    }

    /// Stops auto-paging after the page in flight (⋯ menu → Pause scanning).
    public func pause() {
        pauseRequested = true
        if !inFlight, phase == .idle || phase == .scanning { phase = .paused }
    }

    /// Continue at the limit: raises it by the configured limit (never past `maximumLimit`), adds the keys held back
    /// from the last page, then resumes auto-paging in auto mode; manual mode returns idle and waits for Load more.
    @discardableResult
    public func continueScanning() async -> KeyIndexStatus {
        guard status.canContinue, !inFlight else { return status }
        limit = min(limit + configuration.limit, KeyIndexConfiguration.maximumLimit)
        // Held-back keys count against the raised limit too, so a page larger than the step never overshoots it.
        overflow = ingest(overflow, room: max(limit - ends.count, 0))
        updatePhaseAfterPage()
        guard phase == .scanning else { return status }
        phase = .idle
        return mode == .auto ? await autoPage() : status
    }

    /// Starts over: clears every key and drops any page in flight. A new filter replaces the current one (AC2);
    /// without one the filter is kept, as Refresh wants (FR-KB09).
    public func restart(filter: KeyFilter? = nil) {
        if let filter { configuration.filter = filter }
        generation += 1
        arena = []; ends = []; metadata = []; overflow = []
        slots = ContiguousArray(repeating: 0, count: 1_024)
        treeBuild += 1
        tree = NamespaceTree(separator: tree.separator, build: treeBuild)
        cursor = Data("0".utf8); started = false
        limit = configuration.limit; phase = .idle; inFlight = false; pauseRequested = false
    }

    /// Sends one SCAN and adds its keys. Returns whether another page may follow (for the auto-page loop).
    private func scanPage() async -> Bool {
        guard !inFlight else { return false }
        switch phase {
        case .complete, .limitReached: return false
        case .idle, .scanning, .paused, .failed: break
        }
        if ends.count >= limit { phase = .limitReached; return false }
        inFlight = true; phase = .scanning
        let scanGeneration = generation
        let filter = configuration.filter
        let operation = filter.scan(cursor: cursor, count: configuration.pageSize)
        var result: Result<Page, KeyIndexError>
        do throws(DataCommandError) {
            result = Self.parse(try await service.execute(.operation(operation), origin: .browser, context: context).reply)
        } catch {
            result = .failure(KeyIndexError(code: error.code, message: Self.describe(error, command: "SCAN")))
        }
        // A type SCAN can't select is checked here, before the cursor moves: a failed check retries the same page.
        if case .success(let page) = result, let wanted = filter.clientSideType, scanGeneration == generation {
            result = await keys(page.keys, ofType: wanted, generation: scanGeneration).map { Page(cursor: page.cursor, keys: $0) }
        }
        // A restart while this page was in flight owns the state now; its own scan starts from cursor 0.
        guard scanGeneration == generation else { return false }
        inFlight = false
        switch result {
        case .failure(let error):
            phase = .failed(error)
            return false
        case .success(let page):
            cursor = page.cursor; started = true
            // Keys past the limit are held back rather than dropped: the cursor has already moved past them.
            overflow = ingest(page.keys, room: max(limit - ends.count, 0))
            updatePhaseAfterPage()
            return phase == .scanning
        }
    }

    private func updatePhaseAfterPage() {
        // Held-back keys mean the scan isn't complete even when the cursor is back at 0.
        if !overflow.isEmpty {
            phase = .limitReached
        } else if isCursorDone {
            phase = .complete
        } else if ends.count >= limit {
            phase = .limitReached
        } else {
            phase = .scanning
        }
    }

    private var isCursorDone: Bool { started && cursor == Data("0".utf8) }

    /// TYPE checks in flight at once for a client-side type filter: enough to pipeline, bounded however large the page.
    static let typeCheckWindow = 256

    /// The page's keys whose `TYPE` matches, in page order. The `TYPE`s pipeline on the browser connection, at most
    /// `typeCheckWindow` at a time; any failure fails the page, and a failure or a restart stops sending more.
    /// Keys deleted since SCAN (`none`) are left out.
    private func keys(_ page: [Data], ofType wanted: KeyTypeFilter, generation scanGeneration: Int) async -> Result<[Data], KeyIndexError> {
        let replies = await withTaskGroup(of: (Int, Result<RESPValue, DataCommandError>).self) { group in
            var replies = [Result<RESPValue, DataCommandError>?](repeating: nil, count: page.count)
            var next = 0, stop = false
            func send() {
                guard !stop, next < page.count else { return }
                let offset = next, key = page[offset]; next += 1
                group.addTask { [service, context] in
                    do throws(DataCommandError) {
                        return (offset, .success(try await service.execute(.operation(.type(key: key)), origin: .browser, context: context).reply))
                    } catch { return (offset, .failure(error)) }
                }
            }
            for _ in 0..<Self.typeCheckWindow { send() }
            for await (offset, reply) in group {
                replies[offset] = reply
                // Anything but a type name fails the page, and a restart drops it: either way, send no more.
                switch reply {
                case .success(.simpleString), .success(.bulkString): if scanGeneration != generation { stop = true }
                default: stop = true
                }
                send()
            }
            return replies
        }
        var kept: [Data] = []
        for (key, reply) in zip(page, replies) {
            switch reply {
            case .success(.simpleString(let name))?, .success(.bulkString(let name))?:
                if KeyType(typeName: name) == wanted.keyType { kept.append(key) }
            // Never sent after a stop; every sent reply was awaited, so the failure that stopped it is reported below.
            case nil: continue
            case .failure(let error)?: return .failure(KeyIndexError(code: error.code, message: Self.describe(error, command: "TYPE")))
            case .success(.error(let text))?, .success(.blobError(let text))?: return .failure(Self.serverError(text))
            case .success?: return .failure(Self.malformedType)
            }
        }
        return .success(kept)
    }

    // MARK: - Local filter

    /// Keys searched per call, so the first results of a local filter over a million keys show within the budget (AC3).
    public static let localSearchChunk = 131_072

    /// The loaded keys from `start` on whose bytes contain `query`, searching at most `chunk` keys. The caller asks
    /// again from `searchedThrough` until it reaches `count`; pages loaded meanwhile are searched by the next call.
    public func localMatches(_ query: LocalKeyQuery, from start: Int = 0, chunk: Int = localSearchChunk) -> LocalKeyMatches {
        let lower = min(max(start, 0), ends.count), upper = min(lower + max(chunk, 1), ends.count)
        guard !query.isEmpty else { return LocalKeyMatches(indices: Array(lower..<upper), searchedThrough: upper) }
        var indices: [Int] = []
        arena.withUnsafeBytes { arena in
            var keyStart = lower == 0 ? 0 : ends[lower - 1]
            for index in lower..<upper {
                let keyEnd = ends[index]
                if query.matches(UnsafeRawBufferPointer(rebasing: arena[keyStart..<keyEnd])) { indices.append(index) }
                keyStart = keyEnd
            }
        }
        return LocalKeyMatches(indices: indices, searchedThrough: upper)
    }

    // MARK: - Storage

    /// Adds new keys until `room` new ones were added; duplicates take no room. Returns the keys left over.
    @discardableResult
    func ingest(_ keys: [Data], room: Int = .max) -> [Data] {
        // The tree takes the new keys in one pass once they are all in the arena.
        defer { withKeyBytes { tree.extend(with: $0) } }
        var added = 0
        for (offset, key) in keys.enumerated() {
            if added == room { return keys[offset...].filter { !contains($0) } }
            if insert(key) { added += 1 }
        }
        return []
    }

    func contains(_ key: Data) -> Bool { probe(key).found }

    /// Inserts a key unless it is already loaded (FR-KB02 dedup); true when it was new.
    private func insert(_ key: Data) -> Bool {
        let (slot, found) = probe(key)
        guard !found else { return false }
        arena.append(contentsOf: key)
        ends.append(arena.count)
        // Under a type filter every key added has that type, so its badge needs no TYPE of its own.
        metadata.append(KeyMetadata(type: configuration.filter.type?.keyType ?? .unknown))
        slots[slot] = UInt32(ends.count)
        // Keep the load factor under 3/4 so probes stay short.
        if ends.count * 4 > slots.count * 3 { rehash(capacity: slots.count * 2) }
        return true
    }

    /// The slot holding `key`, or the empty slot where it would go.
    private func probe(_ key: Data) -> (slot: Int, found: Bool) {
        let mask = slots.count - 1
        var slot = Self.hash(key) & mask
        while slots[slot] != 0 {
            if bytes(at: Int(slots[slot]) - 1).elementsEqual(key) { return (slot, true) }
            slot = (slot + 1) & mask
        }
        return (slot, false)
    }

    private func rehash(capacity: Int) {
        var table = ContiguousArray<UInt32>(repeating: 0, count: capacity)
        let mask = capacity - 1
        // Hash straight from the arena so growing the table never copies a key out.
        arena.withUnsafeBytes { buffer in
            for index in 0..<ends.count {
                var slot = Self.hash(UnsafeRawBufferPointer(rebasing: buffer[range(at: index)])) & mask
                while table[slot] != 0 { slot = (slot + 1) & mask }
                table[slot] = UInt32(index + 1)
            }
        }
        slots = table
    }

    private func range(at index: Int) -> Range<Int> { (index == 0 ? 0 : ends[index - 1])..<ends[index] }

    private func bytes(at index: Int) -> ArraySlice<UInt8> { arena[range(at: index)] }

    private static func hash(_ key: Data) -> Int { key.withUnsafeBytes { hash($0) } }

    private static func hash(_ bytes: UnsafeRawBufferPointer) -> Int {
        var hasher = Hasher()
        hasher.combine(bytes: bytes)
        return hasher.finalize()
    }

    // MARK: - Replies

    struct Page: Equatable { var cursor: Data; var keys: [Data] }

    /// `SCAN` answers `[cursor, [key, …]]` on RESP2 and RESP3; anything else is a server or protocol error.
    static func parse(_ reply: RESPValue) -> Result<Page, KeyIndexError> {
        switch reply {
        case .error(let text), .blobError(let text): return .failure(serverError(text))
        case .array(let items) where items.count == 2:
            guard let cursor = bytes(items[0]), !cursor.isEmpty, cursor.allSatisfy({ (0x30...0x39).contains($0) }) else { break }
            let list: [RESPValue]
            switch items[1] {
            case .array(let values), .set(let values): list = values
            default: return .failure(malformed)
            }
            var keys: [Data] = []
            keys.reserveCapacity(list.count)
            for item in list {
                guard let key = bytes(item) else { return .failure(malformed) }
                keys.append(key)
            }
            return .success(Page(cursor: cursor, keys: keys))
        default: break
        }
        return .failure(malformed)
    }

    private static let malformed = KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's SCAN reply wasn't a cursor and a key list.")
    private static let malformedType = KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's TYPE reply wasn't a type name.")

    private static func serverError(_ text: Data) -> KeyIndexError {
        let message = String(decoding: text, as: UTF8.self)
        return KeyIndexError(code: message.hasPrefix("NOPERM") ? "PERMISSION_DENIED" : "SERVER_ERROR", message: message)
    }

    private static func bytes(_ value: RESPValue) -> Data? {
        switch value {
        case .bulkString(let data), .simpleString(let data): return data
        default: return nil
        }
    }

    private static func describe(_ error: DataCommandError, command: String) -> String {
        switch error {
        case .refused(.readOnly(let message)), .refused(.blocked(let message)): return message
        case .refused: return "Keel's safety policy refused \(command)."
        case .invalidRequest(let message): return message
        case .connection(let failure): return failure.message
        case .command(let error): return "The connection failed during \(command) (\(error.code))."
        }
    }
}

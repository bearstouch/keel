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

/// A key's type as `TYPE` / `SCAN … TYPE` name it; `unknown` until fetched (`RowMetadataLoader` fills it for visible rows).
public enum KeyType: UInt8, Sendable, Equatable, CaseIterable {
    case unknown, string, hash, list, set, zset, stream, other
}

/// A key row's expiry as `PTTL` last reported it, on a monotonic clock so it can count down (FR-KB06). Editors read
/// wall-clock expiries with `KeyExpiry` instead.
public enum RowExpiry: Sendable, Equatable {
    /// Not fetched yet.
    case unknown
    /// No expiry (`PTTL` -1): the row shows nothing.
    case persistent
    /// The deadline in milliseconds on the loader's monotonic clock; the row counts down to it locally (NFR-PF07).
    case expires(atMilliseconds: Int64)
    /// The key no longer exists (`PTTL` -2, `TYPE` none): "expired" until the next refresh drops it.
    case gone
}

/// A key's memory size, fetched only on request (FR-KB07).
public enum KeySize: Sendable, Equatable {
    case unknown
    case bytes(Int64)
    /// The server refused or couldn't answer (`NOPERM`, no `MEMORY` on the server, the key is gone): not asked again.
    case unavailable
}

/// Per-key metadata as the index hands it out; it stores it packed (`PackedKeyMetadata`).
public struct KeyMetadata: Sendable, Equatable {
    public var type: KeyType
    /// The key was reported missing or changed elsewhere and is waiting for the next refresh (FR-KB12).
    public var isStale: Bool
    public var expiry: RowExpiry
    public var size: KeySize

    public init(type: KeyType = .unknown, isStale: Bool = false, expiry: RowExpiry = .unknown, size: KeySize = .unknown) {
        self.type = type; self.isStale = isStale; self.expiry = expiry; self.size = size
    }
}

/// `KeyMetadata` as `KeyIndex` stores it: 8 bytes a key, so a million keys stay inside NFR-RS01. The deadline is kept
/// in tenths of a second, rounded up (a countdown shown in seconds loses nothing); one more than 13 years from launch
/// is clamped there. Measured sizes live in a side table: only rows measured on request have one.
struct PackedKeyMetadata {
    var type: KeyType
    /// Bit 0 stale; bits 1–2 the expiry kind (unknown, persistent, expires, gone); bits 3–4 the size kind (unknown,
    /// bytes, unavailable).
    var flags: UInt8
    var deadline: UInt32

    init(_ metadata: KeyMetadata) {
        type = metadata.type; deadline = 0
        var flags: UInt8 = metadata.isStale ? 1 : 0
        switch metadata.expiry {
        case .unknown: break
        case .persistent: flags |= 1 << 1
        case .expires(let milliseconds):
            flags |= 2 << 1
            deadline = UInt32(clamping: (max(milliseconds, 0) + 99) / 100)
        case .gone: flags |= 3 << 1
        }
        switch metadata.size {
        case .unknown: break
        case .bytes: flags |= 1 << 3
        case .unavailable: flags |= 2 << 3
        }
        self.flags = flags
    }

    /// `size` is the side table's entry, used when the kind says bytes.
    func unpacked(size: Int64?) -> KeyMetadata {
        let expiry: RowExpiry =
            switch flags >> 1 & 3 {
            case 1: .persistent
            case 2: .expires(atMilliseconds: Int64(deadline) * 100)
            case 3: .gone
            default: .unknown
            }
        let keySize: KeySize =
            switch flags >> 3 & 3 {
            case 1: size.map(KeySize.bytes) ?? .unknown
            case 2: .unavailable
            default: .unknown
            }
        return KeyMetadata(type: type, isStale: flags & 1 != 0, expiry: expiry, size: keySize)
    }
}

/// Why a SCAN page didn't load. The keys already loaded and the cursor are kept, so Load more retries the same page.
public struct KeyIndexError: Error, Sendable, Equatable {
    /// The shared error code (`docs/architecture.md#errors`).
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

/// Whether a key the user opens still exists (FR-KB12).
public enum KeyPresence: Sendable, Equatable {
    case exists(KeyType)
    /// Deleted or expired elsewhere: the browser says `missingMessage` and offers to remove it from the list.
    case missing
    /// The check itself failed; nothing about the key is known.
    case failed(KeyIndexError)

    public static let missingMessage = "Key no longer exists"
}

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
    /// The database every command goes to; `switchDatabase` moves it (FR-KB08).
    public private(set) var context: DataContext
    public private(set) var configuration: KeyIndexConfiguration

    // Storage: key i is arena[(i == 0 ? 0 : ends[i - 1]) ..< ends[i]].
    private var arena = ContiguousArray<UInt8>()
    private var ends = ContiguousArray<Int>()
    private var metadata = ContiguousArray<PackedKeyMetadata>()
    /// Sizes measured on request (FR-KB07), by key index; usually a few screens' worth, so a table is cheaper than a
    /// column. Bounded by `sizeTableLimit` (NFR-RS01): past it the table starts over and dropped rows read as unknown,
    /// so they are measured again only if they come back into view with Show sizes on.
    private var sizes: [Int: Int64] = [:]
    static let sizeTableLimit = 65_536
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
    /// `stopAutoPage()`: the loop ends after the page in flight without pausing.
    private var stopRequested = false
    /// Bumped by `restart` only, so a page still in flight for the previous scan is dropped when it lands.
    private var scanEpoch = 0
    /// Bumped whenever key indices stop meaning what they meant — a restart, or a key removed from the list — so the
    /// list and metadata answers from before are dropped; the list reads it to notice a restart even when more keys
    /// than before are loaded by the time it reloads.
    public private(set) var generation = 0
    /// Settings → Browser (FR-AP09), read again by every restart, so a new scan takes the applied page size, limit and
    /// default separator while the scan already loaded keeps what it started with. Nil keeps `configuration`.
    private let defaults: (@Sendable () -> BrowserSettings)?
    /// The profile's own separator, which wins over the default one; nil follows the default (FR-KB03).
    private var profileSeparator: NamespaceSeparator?

    /// `separator` is the profile's; nil uses the default separator of `defaults`, or `:` without them.
    public init(
        service: DataCommandService, context: DataContext, configuration: KeyIndexConfiguration = KeyIndexConfiguration(), separator: NamespaceSeparator? = .default,
        defaults: (@Sendable () -> BrowserSettings)? = nil
    ) {
        let browser = defaults?()
        let configuration = browser?.configuration(filter: configuration.filter) ?? configuration
        self.service = service; self.context = context; self.configuration = configuration; self.limit = configuration.limit
        self.defaults = defaults; profileSeparator = separator
        tree = NamespaceTree(separator: separator ?? browser?.namespaceSeparator ?? .default)
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

    /// The keys at `indices` while the index is still at `generation`; nil after a restart or removal moved them, so a
    /// selection made before never names other keys. Indices past the loaded range are skipped.
    public func keys(at indices: [Int], generation expected: Int) -> [Data]? {
        guard expected == generation else { return nil }
        return indices.filter { $0 >= 0 && $0 < ends.count }.map(key(at:))
    }

    public func metadata(at index: Int) -> KeyMetadata { metadata[index].unpacked(size: sizes[index]) }

    public func updateMetadata(at index: Int, _ update: @Sendable (inout KeyMetadata) -> Void) {
        guard metadata.indices.contains(index) else { return }
        var entry = metadata(at: index)
        update(&entry)
        store(entry, at: index)
    }

    private func store(_ entry: KeyMetadata, at index: Int) {
        metadata[index] = PackedKeyMetadata(entry)
        guard case .bytes(let bytes) = entry.size else { sizes[index] = nil; return }
        if sizes[index] == nil, sizes.count >= Self.sizeTableLimit { sizes.removeAll(keepingCapacity: true) }
        sizes[index] = bytes
    }

    /// What the visible `indices` still need: `TYPE` while the type is unknown, `PTTL` while the expiry is, and — only
    /// with `sizes` — `MEMORY USAGE` for at most `sizeLimit` keys. Indices past the loaded range and repeats are
    /// skipped; a gone key needs nothing more. The generation lets `applyMetadata` drop answers from before a restart;
    /// the context is the database the work belongs to, so a switch while it is sent can't aim it at another one.
    public func metadataWork(for indices: [Int], sizes: Bool, sizeLimit: Int) -> (generation: Int, context: DataContext, work: [RowMetadataWork]) {
        var work: [RowMetadataWork] = [], seen = Set<Int>(), sizeCount = 0
        for index in indices where metadata.indices.contains(index) && seen.insert(index).inserted {
            let entry = metadata(at: index)
            guard entry.expiry != .gone else { continue }
            let size = sizes && entry.size == .unknown && sizeCount < sizeLimit
            if size { sizeCount += 1 }
            let item = RowMetadataWork(index: index, key: key(at: index), type: entry.type == .unknown, ttl: entry.expiry == .unknown, size: size)
            if item.type || item.ttl || item.size { work.append(item) }
        }
        return (generation, context, work)
    }

    /// Stores fetched metadata unless the index restarted since `metadataWork`; returns the indices that changed.
    public func applyMetadata(_ results: [RowMetadataResult], generation resultGeneration: Int) -> [Int] {
        guard resultGeneration == generation else { return [] }
        var changed: [Int] = []
        for result in results where metadata.indices.contains(result.index) {
            let previous = metadata(at: result.index)
            var entry = previous
            if let type = result.type { entry.type = type }
            if let expiry = result.expiry { entry.expiry = expiry }
            if let size = result.size { entry.size = size }
            // A key reported gone waits for the next refresh to leave the list (FR-KB06, FR-KB12).
            if entry.expiry == .gone { entry.isStale = true }
            if entry != previous { store(entry, at: result.index); changed.append(result.index) }
        }
        return changed
    }

    /// Bytes the index holds in its buffers (capacity, not just use) — the figure NFR-RS01 budgets.
    public var storageBytes: Int {
        arena.capacity + ends.capacity * MemoryLayout<Int>.stride + metadata.capacity * MemoryLayout<PackedKeyMetadata>.stride
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
        profileSeparator = separator
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
                    return NamespaceEntry(child: child, name: Data(fullNames ? keys[index] : tree.name(of: child, keys)), keyCount: 1, metadata: metadata(at: index))
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
        let epoch = scanEpoch
        _ = await scanPage()
        // A restart while the page was in flight owns the phase; only a finished page of this scan settles to idle.
        if epoch == scanEpoch, !inFlight, phase == .scanning { phase = .idle }
        return status
    }

    /// Auto-page: keeps scanning until the cursor returns to 0, the limit is reached, `pause()` is called, a page
    /// fails or the calling task is cancelled. The UI calls it while the list is visible and cancels it when hidden.
    @discardableResult
    public func autoPage() async -> KeyIndexStatus {
        guard !inFlight else { mode = .auto; return status }
        mode = .auto; pauseRequested = false; stopRequested = false
        let epoch = scanEpoch
        // Load more during the loop switches to manual, which ends the loop after the page in flight.
        while !Task.isCancelled, !pauseRequested, !stopRequested, mode == .auto, await scanPage() {}
        // A restart during the loop owns the phase; otherwise a loop that stopped mid-scan is paused or idle.
        if epoch == scanEpoch, !inFlight, phase == .scanning { phase = pauseRequested ? .paused : .idle }
        return status
    }

    /// ⋯ → Auto-page off: manual mode, which ends an auto-page loop after the page in flight and leaves the scan
    /// waiting for Load more. On, the caller then runs `autoPage()`.
    public func setPagingMode(_ mode: KeyPagingMode) {
        self.mode = mode
        if mode == .manual { pauseRequested = false; if phase == .paused { phase = .idle } }
    }

    /// Ends an auto-page loop after the page in flight without pausing it (the list hid, the scan restarts): the mode
    /// stays auto and the next `autoPage()` continues from the cursor. Unlike cancelling the calling task, the page in
    /// flight lands rather than failing.
    public func stopAutoPage() { stopRequested = true }

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
        // A new scan starts from the applied settings; the tree is rebuilt below anyway, so a new default separator
        // costs nothing extra here.
        let browser = defaults?()
        if let browser { configuration = browser.configuration(filter: configuration.filter) }
        scanEpoch += 1; generation += 1
        arena = []; ends = []; metadata = []; sizes = [:]; overflow = []
        slots = ContiguousArray(repeating: 0, count: 1_024)
        treeBuild += 1
        tree = NamespaceTree(separator: profileSeparator ?? browser?.namespaceSeparator ?? tree.separator, build: treeBuild)
        cursor = Data("0".utf8); started = false
        limit = configuration.limit; phase = .idle; inFlight = false; pauseRequested = false; stopRequested = false
    }

    /// The database switcher (FR-KB08): the same index, filters and paging mode on another database, starting empty.
    /// Pages, metadata and checks still in flight for the old database are dropped when they land.
    public func switchDatabase(_ database: Int) {
        guard database != context.database else { return }
        context.database = database
        restart()
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
        let epoch = scanEpoch
        let filter = configuration.filter
        let operation = filter.scan(cursor: cursor, count: configuration.pageSize)
        var result: Result<Page, KeyIndexError>
        do throws(DataCommandError) {
            result = Self.parse(try await service.execute(.operation(operation), origin: .browser, context: context).reply)
        } catch {
            result = .failure(KeyIndexError(code: error.code, message: Self.describe(error, command: "SCAN")))
        }
        // A type SCAN can't select is checked here, before the cursor moves: a failed check retries the same page.
        if case .success(let page) = result, let wanted = filter.clientSideType, epoch == scanEpoch {
            result = await keys(page.keys, ofType: wanted, epoch: epoch).map { Page(cursor: page.cursor, keys: $0) }
        }
        // A restart while this page was in flight owns the state now; its own scan starts from cursor 0.
        guard epoch == scanEpoch else { return false }
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
    private func keys(_ page: [Data], ofType wanted: KeyTypeFilter, epoch: Int) async -> Result<[Data], KeyIndexError> {
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
                case .success(.simpleString), .success(.bulkString): if epoch != scanEpoch { stop = true }
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

    // MARK: - Database size and missing keys

    /// `DBSIZE` for this index's database: the total the footer shows beside the loaded count (FR-KB09).
    public func databaseSize() async -> Result<Int, KeyIndexError> {
        let reply: RESPValue
        do throws(DataCommandError) { reply = try await service.execute(.operation(.databaseSize), origin: .browser, context: context).reply } catch {
            return .failure(KeyIndexError(code: error.code, message: Self.describe(error, command: "DBSIZE")))
        }
        switch reply {
        case .integer(let count) where count >= 0: return .success(Int(count))
        case .error(let text), .blobError(let text): return .failure(Self.serverError(text))
        default: return .failure(KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's DBSIZE reply wasn't a count."))
        }
    }

    /// The loaded key with these bytes; nil when it isn't loaded (after a restart, until its page loads again).
    public func index(of key: Data) -> Int? {
        let (slot, found) = probe(key)
        return found ? Int(slots[slot]) - 1 : nil
    }

    /// Opening a key checks that it still exists with one `TYPE` (FR-KB12). A missing key is marked stale and gone in
    /// the list (it reads "expired" until removed or refreshed); an existing one gets its current type. A switch or
    /// restart while the reply was out leaves the index alone: the answer was about the previous scan.
    public func presence(of key: Data) async -> KeyPresence {
        let epoch = scanEpoch
        let reply: RESPValue
        do throws(DataCommandError) { reply = try await service.execute(.operation(.type(key: key)), origin: .browser, context: context).reply } catch {
            return .failed(KeyIndexError(code: error.code, message: Self.describe(error, command: "TYPE")))
        }
        let presence: KeyPresence
        switch reply {
        // `none`: deleted or expired elsewhere since SCAN listed it.
        case .simpleString(let name), .bulkString(let name): presence = KeyType(typeName: name).map(KeyPresence.exists) ?? .missing
        case .error(let text), .blobError(let text): return .failed(Self.serverError(text))
        default: return .failed(Self.malformedType)
        }
        if epoch == scanEpoch, let index = index(of: key) {
            updateMetadata(at: index) { entry in
                switch presence {
                case .exists(let type):
                    entry.type = type
                    // Recreated since a PTTL found it gone: it is back, and its TTL is unknown again.
                    if entry.expiry == .gone { entry.expiry = .unknown; entry.isStale = false }
                default: entry.expiry = .gone; entry.isStale = true
                }
            }
        }
        return presence
    }

    /// "Remove from List" for a missing key (FR-KB12): drops it from the loaded keys without touching the server or
    /// the scan's cursor. Later keys move down one index, so the generation changes and the list re-reads its rows.
    /// O(loaded keys) — the arena, the dedup table and the tree are rebuilt — which is fine for one user action.
    @discardableResult
    public func remove(key: Data) -> Bool { remove(keys: [key]) == 1 }

    /// Drops every loaded key among `keys` in one rebuild (a multi-key delete, FR-SF04); keys not loaded are skipped.
    /// Returns how many were removed; the generation changes only when that is more than zero.
    @discardableResult
    public func remove(keys: some Sequence<Data>) -> Int {
        let removed = Set(keys.compactMap { index(of: $0) })
        guard !removed.isEmpty else { return 0 }
        var keptArena = ContiguousArray<UInt8>(), keptEnds = ContiguousArray<Int>(), keptMetadata = ContiguousArray<PackedKeyMetadata>()
        keptArena.reserveCapacity(arena.count); keptEnds.reserveCapacity(ends.count - removed.count); keptMetadata.reserveCapacity(ends.count - removed.count)
        // Old index → new index, for the sizes measured so far.
        var newIndex = [Int](repeating: -1, count: ends.count)
        for index in 0..<ends.count where !removed.contains(index) {
            newIndex[index] = keptEnds.count
            keptArena.append(contentsOf: arena[range(at: index)])
            keptEnds.append(keptArena.count)
            keptMetadata.append(metadata[index])
        }
        arena = keptArena; ends = keptEnds; metadata = keptMetadata
        var moved: [Int: Int64] = [:]
        for (index, size) in sizes where index < newIndex.count && newIndex[index] >= 0 { moved[newIndex[index]] = size }
        sizes = moved
        rehash(capacity: slots.count)
        treeBuild += 1
        tree = NamespaceTree(separator: tree.separator, build: treeBuild)
        withKeyBytes { tree.extend(with: $0) }
        generation += 1
        return removed.count
    }

    /// A key the user just made (a rename's new name, FR-ED10) joins the loaded keys at the end, so it can be selected
    /// before a refresh; one the filter wouldn't list stays out (false). A key already loaded (the key a rename replaced)
    /// is another value now: it takes the new type and its TTL, size and stale mark are read again.
    @discardableResult
    public func add(key: Data, type: KeyType) -> Bool {
        let filter = configuration.filter
        if let pattern = filter.pattern, !GlobPattern.matches(pattern, key) { return false }
        if let wanted = filter.type?.keyType, wanted != type { return false }
        guard ingest([key]).isEmpty, let added = index(of: key) else { return false }
        updateMetadata(at: added) { $0 = KeyMetadata(type: type) }
        generation += 1
        return true
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
        metadata.append(PackedKeyMetadata(KeyMetadata(type: configuration.filter.type?.keyType ?? .unknown)))
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

    static let malformed = KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's SCAN reply wasn't a cursor and a key list.")
    static let malformedType = KeyIndexError(code: "PROTOCOL_ERROR", message: "The server's TYPE reply wasn't a type name.")

    static func serverError(_ text: Data) -> KeyIndexError {
        let message = String(decoding: text, as: UTF8.self)
        return KeyIndexError(code: message.hasPrefix("NOPERM") ? "PERMISSION_DENIED" : "SERVER_ERROR", message: message)
    }

    private static func bytes(_ value: RESPValue) -> Data? {
        switch value {
        case .bulkString(let data), .simpleString(let data): return data
        default: return nil
        }
    }

    static func describe(_ error: DataCommandError, command: String) -> String {
        switch error {
        case .refused(.readOnly(let message)), .refused(.blocked(let message)): return message
        case .refused: return "Keel's safety policy refused \(command)."
        case .invalidRequest(let message): return message
        case .connection(let failure): return failure.message
        case .command(let error): return "The connection failed during \(command) (\(error.code))."
        case .conflict: return "The key changed since it was loaded."
        }
    }
}

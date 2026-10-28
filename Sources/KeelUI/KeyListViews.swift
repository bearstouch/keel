import AppKit
import KeelCore
import SwiftUI

/// The tree view. ⇧⌘T reaches it through the responder chain while the list has focus.
public final class KeyListOutlineView: NSOutlineView {
    weak var owner: KeyListDataSource?

    @objc public func toggleKeyListMode(_ sender: Any?) { if let owner { Task { await owner.toggleMode() } } }

    public override func keyDown(with event: NSEvent) { if owner?.handlesDelete(event) != true { super.keyDown(with: event) } }

    public override var focusRingMaskBounds: NSRect { KeyListFocus.maskBounds(visibleRect) }
    public override func drawFocusRingMask() { KeyListFocus.drawMask(visibleRect) }
    public override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); KeyListFocus.follow(self, #selector(visibleRectChanged)) }
    @objc func visibleRectChanged(_ note: Notification) { noteFocusRingMaskChanged() }

    /// AppKit's disclosure triangle has no name of its own (NFR-AX01); the row beside it names the folder.
    public override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        // VoiceOver reads the button's cell.
        if identifier == NSOutlineView.disclosureButtonIdentifier, let button = view as? NSButton { button.cell?.setAccessibilityLabel(Self.disclosureLabel) }
        return view
    }

    static let disclosureLabel = "Show or hide the folder's keys"
}

/// The flat view.
public final class KeyListTableView: NSTableView {
    weak var owner: KeyListDataSource?

    @objc public func toggleKeyListMode(_ sender: Any?) { if let owner { Task { await owner.toggleMode() } } }

    public override func keyDown(with event: NSEvent) { if owner?.handlesDelete(event) != true { super.keyDown(with: event) } }

    public override var focusRingMaskBounds: NSRect { KeyListFocus.maskBounds(visibleRect) }
    public override func drawFocusRingMask() { KeyListFocus.drawMask(visibleRect) }
    public override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); KeyListFocus.follow(self, #selector(visibleRectChanged)) }
    @objc func visibleRectChanged(_ note: Notification) { noteFocusRingMaskChanged() }
}

/// The lists' focus ring (NFR-AX02): around the visible rows, inset so the scroll view doesn't clip it, whether or not a
/// row is selected.
enum KeyListFocus {
    static func maskBounds(_ visible: NSRect) -> NSRect { visible.insetBy(dx: 3, dy: 3) }
    static func drawMask(_ visible: NSRect) { NSBezierPath(roundedRect: maskBounds(visible), xRadius: 6, yRadius: 6).fill() }

    /// The mask follows the visible rect, so scrolling or resizing the pane moves it; AppKit redraws the ring only when
    /// told (`noteFocusRingMaskChanged`), else it would scroll away with the rows.
    @MainActor static func follow(_ view: NSView, _ selector: Selector) {
        // Never `removeObserver(view, name:object: nil)`: AppKit's table observes its clip view as itself.
        guard let clip = view.superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] { NotificationCenter.default.addObserver(view, selector: selector, name: name, object: clip) }
    }
}

public enum KeyListCommands {
    /// View → Toggle Tree / Flat (⇧⌘T), sent to the first responder.
    public static let toggleMode = #selector(KeyListOutlineView.toggleKeyListMode(_:))
    /// View → Filter Keys (⌘F) posts this with the key window; that window's filter field takes focus. A notification
    /// rather than the responder chain, so ⌘F works wherever the focus is in the window, the filter field included.
    public static let focusFilterNotification = Notification.Name("com.bearstouch.keel.focusKeyFilter")
    /// View → Refresh (⌘R), posted with the key window: its browser rescans keeping filters and selection (FR-KB09).
    public static let refreshNotification = Notification.Name("com.bearstouch.keel.refreshKeys")
    /// View → Database → db0…db9 (⌥⌘0…⌥⌘9), posted with the key window and the index under `databaseKey` (FR-KB08).
    public static let selectDatabaseNotification = Notification.Name("com.bearstouch.keel.selectDatabase")
    public static let databaseKey = "database"
    /// Key → New Key… (⇧⌘N), posted with the key window: its browser shows the new-key sheet (FR-ED14).
    public static let newKeyNotification = Notification.Name("com.bearstouch.keel.newKey")
    /// Key → Delete Selected Keys… (⌘⌫), posted with the key window: the typed confirmation for a multi-key selection
    /// (FR-SF04), the normal one for the open key (FR-ED12).
    public static let deleteNotification = Notification.Name("com.bearstouch.keel.deleteKeys")
}

/// File → Save Changes (⌘S) and Revert Changes (⌘Z), posted with the key window: its open editor saves or reverts.
public enum EditorCommands {
    public static let saveNotification = Notification.Name("com.bearstouch.keel.saveEdits")
    public static let revertNotification = Notification.Name("com.bearstouch.keel.revertEdits")
    /// Key → Rename Key… (⌘E) and Set TTL… (⌥⌘E): the open editor's sheet (FR-ED13).
    public static let renameNotification = Notification.Name("com.bearstouch.keel.renameKey")
    public static let setTTLNotification = Notification.Name("com.bearstouch.keel.setKeyTTL")
}

/// One 32 px row (08 Design → Key list): name in mono, then the muted count or TTL, then the type badge. Frames are set
/// in `layout()` rather than with constraints, so reusing a cell while scrolling costs a few assignments.
final class KeyListCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("KeyListCell")

    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let badge = KeyListBadge()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = Tokens.NS.mono(12.5); name.textColor = Tokens.NS.fg
        name.lineBreakMode = .byTruncatingTail; name.cell?.truncatesLastVisibleLine = true
        meta.font = Tokens.NS.interface(11); meta.textColor = Tokens.NS.muted
        for label in [name, meta] { label.setAccessibilityElement(false); addSubview(label) }
        addSubview(badge)
        // The cell is the one element VoiceOver reads: name, type and TTL (AC3); the outline adds level and expansion.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    /// Nil shows an empty row until its content is fetched.
    func show(_ row: KeyListRow?) {
        name.stringValue = row?.name ?? ""
        meta.stringValue = row?.meta ?? ""
        badge.show(row?.badge, type: row?.type ?? .unknown)
        setAccessibilityLabel(row?.accessibilityLabel ?? "Loading")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var trailing = bounds.maxX - 10
        if !badge.isHidden {
            badge.frame = NSRect(x: trailing - 40, y: (height - 16) / 2, width: 40, height: 16)
            trailing -= 48
        }
        if !meta.stringValue.isEmpty {
            meta.sizeToFit()
            let size = meta.frame.size
            meta.frame = NSRect(x: trailing - size.width, y: (height - size.height) / 2, width: size.width, height: size.height)
            trailing -= size.width + 8
        }
        meta.isHidden = meta.stringValue.isEmpty
        let nameHeight = name.intrinsicContentSize.height
        name.frame = NSRect(x: 2, y: (height - nameHeight) / 2, width: max(trailing - 2, 0), height: nameHeight)
    }
}

/// The type badge: text on its type's fill (DS-04: the text carries the meaning, the color only helps).
final class KeyListBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var type = KeyType.unknown

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = Tokens.NS.interface(9.5, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    func show(_ text: String?, type: KeyType) {
        isHidden = text == nil
        self.type = type
        // 0.04 em tracking, as on the board.
        label.attributedStringValue = NSAttributedString(string: text ?? "", attributes: [.kern: 0.38, .font: label.font as Any])
        needsDisplay = true; needsLayout = true
    }

    override func updateLayer() {
        let colors = Tokens.NS.badge(type)
        label.textColor = colors.fg
        // Layer colors don't follow the appearance on their own; resolve them for this view's.
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = colors.fill.cgColor }
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// Selected rows are a rounded `selection` fill with the text unchanged, as on the `Main` board.
final class KeyListRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Tokens.NS.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 7, yRadius: 7).fill()
    }

    // The fill is light, so the cells keep their normal (not inverted) text colors.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Holds a model-owned view (a tab's key list or console) as its only subview. The models keep their views for the
/// tab's life, so a representable that SwiftUI reuses for another tab's model must swap the view rather than keep
/// showing the first tab's; and a tab moved to another window takes its view along without the old window's
/// container removing it later.
final class ModelViewContainer: NSView {
    private(set) weak var hosted: NSView?

    /// Shows `view` filling the container; false when it already does.
    @discardableResult func show(_ view: NSView) -> Bool {
        guard hosted !== view || view.superview !== self else { return false }
        release()
        view.frame = bounds; view.autoresizingMask = [.width, .height]
        addSubview(view)  // Takes it from any other window's container.
        hosted = view
        return true
    }

    /// Lets the hosted view go, unless another container has taken it since.
    func release() {
        if let hosted, hosted.superview === self { hosted.removeFromSuperview() }
        hosted = nil
    }
}

/// Hosts the data source's scroll view in SwiftUI; the data source swaps its document view on ⇧⌘T.
struct KeyListHost: NSViewRepresentable {
    let dataSource: KeyListDataSource

    func makeNSView(context: Context) -> ModelViewContainer {
        let container = ModelViewContainer()
        container.show(dataSource.scrollView)
        return container
    }

    func updateNSView(_ container: ModelViewContainer, context: Context) { container.show(dataSource.scrollView) }

    static func dismantleNSView(_ container: ModelViewContainer, coordinator: ()) { container.release() }
}

/// The key list's ⋯ paging items (FR-KB02).
public enum KeyListPagingCommand: Sendable, Equatable {
    /// On: scan page after page up to the loaded-key limit; off: back to Load more.
    case autoPage(Bool)
    case pause, resume
}

/// The key list with the filter field above it and its one-line footer ("250,000 of 1.2M keys loaded · Load more").
/// The browser that owns the scan (KEEL-025/026) calls `reload()` after each page.
public struct KeyListPane: View {
    @ObservedObject var dataSource: KeyListDataSource
    /// The filter field's model; nil hides the field.
    let filter: KeyFilterModel?
    /// Runs the footer's action (Load more, Continue, Retry) on the index; the pane reloads afterwards.
    let perform: (KeyIndexFooter.Action) async -> Void
    /// The ⋯ menu's Auto-page, Pause and Resume (FR-KB02); nil hides them.
    let paging: ((KeyListPagingCommand) async -> Void)?

    public init(
        dataSource: KeyListDataSource, filter: KeyFilterModel? = nil, perform: @escaping (KeyIndexFooter.Action) async -> Void,
        paging: ((KeyListPagingCommand) async -> Void)? = nil
    ) {
        self.dataSource = dataSource; self.filter = filter; self.perform = perform; self.paging = paging
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let filter { KeyFilterBar(model: filter) }
            KeyListHost(dataSource: dataSource)
            footer
        }
        .background(Tokens.bg)
    }

    private var footer: some View {
        let footer = dataSource.footer
        return HStack(spacing: 4) {
            Text(([footer.summary, footer.notice] as [String?]).compactMap { $0 }.joined(separator: " · ") + (footer.action == nil ? "" : " ·"))
            if let action = footer.action {
                Button(action.rawValue) {
                    Task {
                        await perform(action); await dataSource.reload()
                    }
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.accent)
            }
            Spacer(minLength: 0)
            if dataSource.metadataLoader != nil || dataSource.onBulkDelete != nil || paging != nil { moreMenu }
        }
        .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(footer.text)
    }

    /// The list's secondary actions ("show less, reveal on demand"). Auto-page keeps scanning up to the limit and Pause
    /// stops it after the page in flight (FR-KB02); Show Sizes measures the visible rows (FR-KB07); Delete Keys
    /// Matching… deletes what the server pattern filter matches (FR-SF05), so it needs one.
    private var moreMenu: some View {
        Menu {
            if let paging {
                let status = dataSource.pagingStatus
                Toggle("Auto-page", isOn: Binding(get: { status.mode == .auto }, set: { on in Task { await paging(.autoPage(on)) } }))
                if status.mode == .auto, status.phase == .scanning { Button("Pause Scanning") { Task { await paging(.pause) } } }
                if status.mode == .auto, status.phase == .paused { Button("Resume Scanning") { Task { await paging(.resume) } } }
            }
            if dataSource.metadataLoader != nil {
                Toggle("Show Sizes", isOn: Binding(get: { dataSource.showsSizes }, set: { on in Task { await dataSource.setShowsSizes(on) } }))
            }
            if let bulkDelete = dataSource.onBulkDelete {
                Divider()
                let applied = filter?.applied
                let title = applied?.pattern.map { "Delete Keys Matching \(KeyDisplay.name($0))…" } ?? "Delete Keys Matching…"
                // Shown but disabled for what the job refuses (no pattern, `*`, a module-type filter).
                let refused = applied.flatMap { BulkDeleteJob.refusal(pattern: $0.pattern ?? Data(), type: $0.type) } != nil
                Button(title, action: bulkDelete).disabled(refused)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More key list actions")
        .help("More")
    }
}

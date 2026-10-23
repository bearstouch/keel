import AppKit
import KeelCore
import SwiftUI

/// The tree view. ⇧⌘T reaches it through the responder chain while the list has focus.
public final class KeyListOutlineView: NSOutlineView {
    weak var owner: KeyListDataSource?

    @objc public func toggleKeyListMode(_ sender: Any?) { if let owner { Task { await owner.toggleMode() } } }
}

/// The flat view.
public final class KeyListTableView: NSTableView {
    weak var owner: KeyListDataSource?

    @objc public func toggleKeyListMode(_ sender: Any?) { if let owner { Task { await owner.toggleMode() } } }
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

/// Hosts the data source's scroll view in SwiftUI; the data source swaps its document view on ⇧⌘T.
struct KeyListHost: NSViewRepresentable {
    let dataSource: KeyListDataSource

    func makeNSView(context: Context) -> NSScrollView { dataSource.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// The key list with the filter field above it and its one-line footer ("250,000 of 1.2M keys loaded · Load more").
/// The browser that owns the scan (KEEL-025/026) calls `reload()` after each page.
public struct KeyListPane: View {
    @ObservedObject var dataSource: KeyListDataSource
    /// The filter field's model; nil hides the field.
    let filter: KeyFilterModel?
    /// Runs the footer's action (Load more, Continue, Retry) on the index; the pane reloads afterwards.
    let perform: (KeyIndexFooter.Action) async -> Void

    public init(dataSource: KeyListDataSource, filter: KeyFilterModel? = nil, perform: @escaping (KeyIndexFooter.Action) async -> Void) {
        self.dataSource = dataSource; self.filter = filter; self.perform = perform
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
            if dataSource.metadataLoader != nil { moreMenu }
        }
        .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(footer.text)
    }

    /// The list's secondary actions ("show less, reveal on demand"). Show Sizes measures the visible rows (FR-KB07).
    private var moreMenu: some View {
        Menu {
            Toggle("Show Sizes", isOn: Binding(get: { dataSource.showsSizes }, set: { on in Task { await dataSource.setShowsSizes(on) } }))
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More key list actions")
        .help("More")
    }
}

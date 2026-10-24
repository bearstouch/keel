import AppKit
import KeelCore
import SwiftUI

/// The value viewer on `codeBg` (08 Design → Editor): the element's name, the JSON / escaping note, the
/// Text / JSON / Hex / Raw switch at the top right, then the value.
struct ValueViewerPanel: View {
    @ObservedObject var model: ValueViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Tokens.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.title).font(Tokens.mono(12.5, weight: .semibold)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.middle)
            if let state = model.state { ViewerNote(state: state) }
            Spacer(minLength: 0)
            ViewerSwitch(mode: model.state?.mode) { model.show($0) }
        }
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 42)
    }

    @ViewBuilder private var content: some View {
        if let state = model.state {
            if state.mode == .hex { HexView(bytes: state.bytes) } else { ViewerTextView(model: model) }
        } else {
            ProgressView().controlSize(.small).padding(16).accessibilityLabel("Preparing the value")
        }
    }
}

/// One short line beside the name: "✓ Valid JSON", the JSON error's line and column, a Raw parse error, or that
/// Text shows some bytes escaped. Never color alone: each says what it means.
private struct ViewerNote: View {
    let state: ValueViewerState

    var body: some View {
        if let note {
            Text(note.text).font(Tokens.interface(12)).foregroundStyle(note.color).lineLimit(1).truncationMode(.tail)
                .help(note.text)
        }
    }

    private var note: (text: String, color: Color)? {
        switch state.mode {
        case .json: state.jsonError.map { ("Invalid JSON · \($0.description)", Tokens.danger) } ?? ("✓ Valid JSON", Tokens.success)
        case .raw: state.rawError.map { ($0.message, Tokens.danger) }
        case .text: state.escaped ? (#"Bytes that aren't text show as \xNN"#, Tokens.muted) : nil
        case .hex: nil
        }
    }
}

/// The viewer switch: segments on a `segBg` track, the selected one `segOn` at 600 (08 Design → Editor).
private struct ViewerSwitch: View {
    let mode: ValueViewMode?
    let select: (ValueViewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ValueViewMode.allCases, id: \.self) { item in
                let selected = item == mode
                Button {
                    select(item)
                } label: {
                    Text(item.rawValue).font(Tokens.interface(12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Tokens.fg : Tokens.muted)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(selected ? Tokens.segOn : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: selected ? Tokens.segShadow : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Tokens.segBg, in: RoundedRectangle(cornerRadius: 7))
        .disabled(mode == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View value as")
    }
}

// MARK: - Text, JSON and Raw

/// An `NSTextView` for Text, JSON and Raw: JetBrains Mono 12.5 at 1.7 line height, JSON colored by token. Every
/// automatic substitution is off, so what the user types is exactly what is saved (AC1).
struct ViewerTextView: NSViewRepresentable {
    @ObservedObject var model: ValueViewerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.drawsBackground = false; text.isRichText = false; text.importsGraphics = false
        // ⌘Z is File → Revert Changes in the editor (03 → Value editors), so the text view keeps no undo of its own.
        text.allowsUndo = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false; text.isGrammarCheckingEnabled = false; text.smartInsertDeleteEnabled = false
        text.textContainerInset = NSSize(width: 11, height: 4)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.typingAttributes = Self.base
        text.insertionPointColor = Tokens.NS.fg
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let state = model.state else { return }
        // The same view identity can carry another session's viewer (the same key name after a database switch).
        if context.coordinator.model !== model { context.coordinator.model = model; context.coordinator.revision = -1 }
        text.isEditable = model.isEditable && state.mode.isEditable
        text.setAccessibilityLabel("Value as \(state.mode.rawValue)")
        // Only a new rendering replaces the contents; the user's typing is already in the view.
        guard context.coordinator.revision != model.revision else { return }
        context.coordinator.revision = model.revision
        text.textStorage?.setAttributedString(Self.attributed(state))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollToBeginningOfDocument(nil)
    }

    private static let base: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 21; paragraph.maximumLineHeight = 21
        return [.font: Tokens.NS.mono(12.5), .foregroundColor: Tokens.NS.fg, .paragraphStyle: paragraph]
    }()

    static func attributed(_ state: ValueViewerState) -> NSAttributedString {
        let string = NSMutableAttributedString(string: state.text, attributes: base)
        for span in state.jsonSpans {
            let color: NSColor =
                switch span.kind {
                case .key: Tokens.NS.jsonKey
                case .string: Tokens.NS.jsonString
                case .literal: Tokens.NS.jsonLiteral
                }
            string.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.location, length: span.length))
        }
        return string
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ValueViewerModel
        var revision = -1

        init(model: ValueViewerModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            model.edit(text.string)
        }
    }
}

// MARK: - Hex

/// Offset, hex and ASCII columns in an `NSTableView`: rows are formatted as they scroll into view, so a 1 MiB value
/// (65,536 lines) opens at once (AC3). Read-only.
struct HexView: NSViewRepresentable {
    let bytes: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil; table.backgroundColor = .clear; table.gridStyleMask = []
        table.selectionHighlightStyle = .none; table.rowHeight = 21; table.intercellSpacing = NSSize(width: 16, height: 0)
        table.style = .plain; table.usesAutomaticRowHeights = false
        let width = ("0" as NSString).size(withAttributes: [.font: Tokens.NS.mono(12.5)]).width
        for (id, characters) in [("offset", 8), ("hex", 48), ("ascii", HexLayout.bytesPerLine)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = ceil(width * CGFloat(characters)) + 4; column.resizingMask = []
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.setAccessibilityLabel("Value as Hex: offset, hex and ASCII columns")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.bytes != bytes, let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.bytes = bytes
        table.reloadData()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var bytes = Data()

        func numberOfRows(in tableView: NSTableView) -> Int { HexLayout.lineCount(bytes.count) }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier else { return nil }
            let field = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? Self.label(id)
            let line = HexLayout.line(row, of: bytes)
            switch id.rawValue {
            case "offset": field.stringValue = line.offset
            case "hex": field.stringValue = line.hex
            default: field.stringValue = line.ascii
            }
            return field
        }

        private static func label(_ id: NSUserInterfaceItemIdentifier) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.identifier = id; field.font = Tokens.NS.mono(12.5); field.isSelectable = true
            field.textColor = id.rawValue == "offset" ? Tokens.NS.muted : Tokens.NS.fg
            field.lineBreakMode = .byClipping
            return field
        }
    }
}

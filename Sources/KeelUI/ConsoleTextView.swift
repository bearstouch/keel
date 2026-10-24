import AppKit
import KeelCore

/// The console palette (08 Design → Console): Trellis's terminal colors, dark in both themes (DS-05).
enum ConsoleTheme {
    static let background = color(.background)
    static let output = color(.output)
    static let command = color(.command)
    static let prompt = color(.prompt)
    static let notice = color(.notice)
    static let null = color(.null)
    static let error = color(.error)
    static let cursor = color(.cursor)
    static let hint = color(.hint)
    static let list = color(.list)
    static let listBorder = color(.listBorder)
    static let listSelected = color(.listSelected)
    static var font: NSFont { Tokens.NS.mono(14) }
    /// 14 px at 1.7.
    static let lineHeight: CGFloat = 23.8

    private static func color(_ token: KeelTheme.Console) -> NSColor { Swatch(KeelTheme.console[token] ?? 0).nsColor }
}

extension NSAttributedString.Key {
    /// The reply a console line belongs to, for Copy Reply.
    static let consoleReply = NSAttributedString.Key("com.bearstouch.keel.consoleReply")
}

/// The console's text view (02 Architecture → `ConsoleTextView`): the scrollback followed by the prompt and the line
/// being typed, like a terminal. Only the input after the prompt is editable, and only while no command runs. Return
/// runs the line; ↑ / ↓ walk the history, ⌃R searches it; Tab or ⌃Space completes command names from a list of names,
/// with the argument hint drawn after the block cursor; ⌃L clears and ⌃C stops. Undo is off, so a typed secret leaves
/// no copy once the line is replaced by its masked echo.
final class ConsoleTextView: NSTextView {
    weak var model: ConsoleModel?

    /// UTF-16 offsets: the prompt line starts at `outputEnd`, the editable input at `inputStart`.
    private var outputEnd = 0
    private var inputStart = 0
    private var inputActive = false
    /// The buffer lines on screen, by their buffer numbers, and each one's length (its newline included).
    private var renderedFirst = 0
    private var renderedEnd = 0
    private var lengths: [Int] = []

    private var completion = ConsoleCompletion()
    private var selectedCandidate = 0
    private var hint = ""
    private let list = ConsoleCompletionList()

    static func makeScrollView(model: ConsoleModel) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = ConsoleTheme.background
        // TextKit 1: the hint, the cursor and the completion list are placed from glyph positions.
        let view = ConsoleTextView(usingTextLayoutManager: false)
        view.model = model
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 32, height: 28)
        view.drawsBackground = true; view.backgroundColor = ConsoleTheme.background
        view.insertionPointColor = ConsoleTheme.cursor
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = false; view.isEditable = false; view.isSelectable = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticDataDetectionEnabled = false; view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.selectedTextAttributes = [.backgroundColor: ConsoleTheme.listSelected, .foregroundColor: ConsoleTheme.command]
        view.typingAttributes = ConsoleTextView.attributes(color: ConsoleTheme.command)
        view.setAccessibilityLabel("Redis console")
        view.list.isHidden = true
        view.addSubview(view.list)
        scroll.documentView = view
        return scroll
    }

    private static func attributes(color: NSColor, spacingBefore: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ConsoleTheme.lineHeight; paragraph.maximumLineHeight = ConsoleTheme.lineHeight
        paragraph.paragraphSpacingBefore = spacingBefore
        // The extra line height goes above the text, so center it on the line like CSS line-height does.
        let offset = (ConsoleTheme.lineHeight - (ConsoleTheme.font.ascender - ConsoleTheme.font.descender)) / 4
        return [.font: ConsoleTheme.font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: offset]
    }

    // MARK: - Showing the buffer

    /// Follows `buffer` incrementally: lines it dropped leave the top, new ones go in above the prompt.
    func show(_ buffer: ConsoleBuffer) {
        guard let storage = textStorage else { return }
        let atBottom = visibleRect.maxY >= bounds.maxY - ConsoleTheme.lineHeight * 2
        storage.beginEditing()
        let gone = min(max(buffer.firstIndex - renderedFirst, 0), lengths.count)
        if gone > 0 {
            let length = lengths.prefix(gone).reduce(0, +)
            storage.deleteCharacters(in: NSRange(location: 0, length: length))
            lengths.removeFirst(gone); renderedFirst += gone; outputEnd -= length; inputStart -= length
        }
        // Lines dropped before they were ever drawn.
        if renderedFirst < buffer.firstIndex { renderedFirst = buffer.firstIndex }
        renderedEnd = max(renderedEnd, renderedFirst)
        let fresh = buffer.lines.dropFirst(renderedEnd - buffer.firstIndex)
        if !fresh.isEmpty {
            let text = NSMutableAttributedString()
            for line in fresh {
                let drawn = Self.attributed(line)
                lengths.append(drawn.length); text.append(drawn)
            }
            storage.insert(text, at: outputEnd)
            outputEnd += text.length; inputStart += text.length
            renderedEnd = buffer.endIndex
        }
        storage.endEditing()
        if inputActive, selectedRange().location < inputStart { setSelectedRange(NSRange(location: storage.length, length: 0)) }
        if atBottom || !fresh.isEmpty && inputActive { scrollToEndOfDocument(nil) }
        refreshCompletion()
    }

    private static func attributed(_ line: ConsoleLine) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let color: NSColor, spacingBefore: CGFloat
        switch line.kind {
        case .command(let prompt):
            text.append(NSAttributedString(string: prompt, attributes: attributes(color: ConsoleTheme.prompt, spacingBefore: 14)))
            color = ConsoleTheme.command; spacingBefore = 14
        case .output: color = ConsoleTheme.output; spacingBefore = 0
        case .null: color = ConsoleTheme.null; spacingBefore = 0
        case .error: color = ConsoleTheme.error; spacingBefore = 0
        case .notice: color = ConsoleTheme.notice; spacingBefore = 0
        }
        text.append(NSAttributedString(string: line.text + "\n", attributes: attributes(color: color, spacingBefore: spacingBefore)))
        if let reply = line.reply { text.addAttribute(.consoleReply, value: reply, range: NSRange(location: 0, length: text.length)) }
        return text
    }

    /// The prompt and input appear only while the console takes commands; a new prompt replaces the old one (`SELECT`).
    func setInputActive(_ active: Bool, prompt: String) {
        guard let storage = textStorage else { return }
        let promptText = NSAttributedString(string: prompt, attributes: Self.attributes(color: ConsoleTheme.prompt, spacingBefore: 12))
        if active {
            let range = inputActive ? NSRange(location: outputEnd, length: inputStart - outputEnd) : NSRange(location: outputEnd, length: storage.length - outputEnd)
            if !inputActive || storage.attributedSubstring(from: range).string != prompt {
                storage.replaceCharacters(in: range, with: promptText)
                inputStart = outputEnd + promptText.length
            }
            inputActive = true; isEditable = true
            typingAttributes = Self.attributes(color: ConsoleTheme.command, spacingBefore: 12)
            setSelectedRange(NSRange(location: storage.length, length: 0))
            scrollToEndOfDocument(nil)
        } else if inputActive {
            storage.deleteCharacters(in: NSRange(location: outputEnd, length: storage.length - outputEnd))
            inputStart = outputEnd; inputActive = false; isEditable = false
        }
        refreshCompletion()
    }

    /// The line after the prompt.
    var input: String { inputActive ? (string as NSString).substring(from: inputStart) : "" }

    private func setInput(_ line: String) {
        guard inputActive, let storage = textStorage else { return }
        storage.replaceCharacters(in: NSRange(location: inputStart, length: storage.length - inputStart), with: NSAttributedString(string: line, attributes: typingAttributes))
        setSelectedRange(NSRange(location: storage.length, length: 0))
        refreshCompletion()
    }

    // MARK: - Editing

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        inputActive && affectedCharRange.location >= inputStart && super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard inputActive, let model else { return }
        // Typing with the selection up in the output continues the line.
        if selectedRange().location < inputStart { setSelectedRange(NSRange(location: textStorage?.length ?? 0, length: 0)) }
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if let search = model.search {
            setInput(model.updateSearch(search.query + typed) ?? input)
            return
        }
        // One line: a pasted newline would otherwise run nothing and leave a broken prompt.
        super.insertText(typed.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "), replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func didChangeText() {
        super.didChangeText()
        model?.lineEdited()
        refreshCompletion()
    }

    override func keyDown(with event: NSEvent) {
        if FocusEscape.handle(event, from: self) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "l": model?.clear(); return
            case "c": Task { await model?.stop() }; return
            case "r": if inputActive, let model { setInput(model.reverseSearch() ?? input) }; return
            case " ": acceptCompletion(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        guard inputActive, let model else { super.doCommand(by: selector); return }
        let listShown = !list.isHidden
        switch selector {
        case #selector(insertNewline(_:)):
            let line = input
            model.endSearch()
            // The typed text leaves the view now; the echo that replaces it is masked (FR-CO10).
            setInput("")
            Task { await model.submit(line) }
        case #selector(insertTab(_:)):
            acceptCompletion()
        case #selector(moveUp(_:)) where listShown:
            selectedCandidate = max(selectedCandidate - 1, 0); refreshCompletion(keepSelection: true)
        case #selector(moveDown(_:)) where listShown:
            selectedCandidate = min(selectedCandidate + 1, completion.candidates.count - 1); refreshCompletion(keepSelection: true)
        case #selector(moveUp(_:)):
            model.endSearch()
            if let line = model.historyPrevious(current: input) { setInput(line) }
        case #selector(moveDown(_:)):
            model.endSearch()
            if let line = model.historyNext() { setInput(line) }
        case #selector(cancelOperation(_:)):
            if model.search != nil { model.endSearch(); refreshCompletion() } else if listShown { list.isHidden = true }
        case #selector(deleteBackward(_:)) where model.search != nil:
            let query = model.search?.query ?? ""
            setInput(model.updateSearch(String(query.dropLast())) ?? input)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)), #selector(moveToBeginningOfParagraph(_:)):
            model.endSearch()
            setSelectedRange(NSRange(location: inputStart, length: 0))
        case #selector(moveLeft(_:)) where selectedRange().location <= inputStart && selectedRange().length == 0:
            model.endSearch()
        default:
            if model.search != nil { model.endSearch(); refreshCompletion() }
            super.doCommand(by: selector)
        }
    }

    // MARK: - Completion and hint

    private func acceptCompletion() {
        guard inputActive, let model else { return }
        model.endSearch()
        let current = model.completion(for: input)
        guard current.candidates.indices.contains(selectedCandidate) else { return }
        setInput(current.accept(selectedCandidate, in: input))
    }

    private func refreshCompletion(keepSelection: Bool = false) {
        guard inputActive, let model else {
            hint = ""; list.isHidden = true; needsDisplay = true
            return
        }
        let line = input
        let next = model.completion(for: line)
        if !keepSelection, next.candidates != completion.candidates { selectedCandidate = 0 }
        completion = next
        hint = model.hint(for: line, completion: completion, selected: selectedCandidate)
        if completion.showsList, model.search == nil {
            list.show(completion.candidates, selected: selectedCandidate)
            placeList()
        } else {
            list.isHidden = true
        }
        needsDisplay = true
    }

    /// Under the word being completed, or above it when the line is at the bottom of what is visible.
    private func placeList() {
        let wordOffset = inputStart + String(input.prefix(completion.wordStart)).utf16.count
        let anchor = rect(atCharacter: wordOffset)
        let size = list.fittingSize
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.maxY + 4)
        if origin.y + size.height > visibleRect.maxY { origin.y = anchor.minY - size.height - 4 }
        list.frame = NSRect(origin: origin, size: size)
    }

    /// The line box at a character offset, in view coordinates (the end of the text included).
    private func rect(atCharacter index: Int) -> NSRect {
        guard let layout = layoutManager, let container = textContainer, let length = textStorage?.length, length > 0 else {
            return NSRect(origin: textContainerOrigin, size: NSSize(width: 0, height: ConsoleTheme.lineHeight))
        }
        let origin = textContainerOrigin
        let clamped = min(index, length - 1)
        let glyph = layout.glyphIndexForCharacter(at: clamped)
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let x: CGFloat
        if index >= length {
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        } else {
            x = line.minX + layout.location(forGlyphAt: glyph).x
        }
        // The used rect's top includes the paragraph spacing; the line itself is the bottom `lineHeight`.
        return NSRect(x: origin.x + x, y: origin.y + line.maxY - ConsoleTheme.lineHeight, width: 0, height: ConsoleTheme.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let length = textStorage?.length ?? 0
        guard inputActive, !hint.isEmpty, selectedRange() == NSRange(location: length, length: 0) else { return }
        let line = rect(atCharacter: length)
        let font = ConsoleTheme.font
        let top = line.minY + (line.height - (font.ascender - font.descender)) / 2
        // After the 8 px block cursor.
        NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: ConsoleTheme.hint]).draw(at: NSPoint(x: line.minX + 9, y: top))
    }

    /// The Redis-red block cursor, 8 × 19 like the canvas.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let block = NSRect(x: rect.minX, y: rect.midY - 9.5, width: 8, height: 19)
        if flag {
            ConsoleTheme.cursor.setFill(); block.fill()
        } else {
            setNeedsDisplay(block.insetBy(dx: -1, dy: -1), avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The caret's own invalidation is 1 px wide; the block needs its width.
        var rect = invalidRect
        rect.size.width += 9
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: - Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let storage = textStorage, index < storage.length, let reply = storage.attribute(.consoleReply, at: index, effectiveRange: nil) as? Int {
            let item = menu.addItem(withTitle: "Copy Reply", action: #selector(copyReply(_:)), keyEquivalent: "")
            item.representedObject = reply; item.target = self
        }
        if selectedRange().length > 0 { menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "") }
        menu.addItem(withTitle: "Copy All Output", action: #selector(copyAll(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Console", action: #selector(clearConsole(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = [.command, .option]; clear.target = self
        return menu
    }

    @objc private func copyReply(_ sender: NSMenuItem) {
        guard let reply = sender.representedObject as? Int, let model else { return }
        Self.copyToPasteboard(model.replyText(reply))
    }

    @objc private func copyAll(_ sender: Any?) { if let model { Self.copyToPasteboard(model.allText) } }

    @objc private func clearConsole(_ sender: Any?) { model?.clear() }

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The completion list (08 Design → Console): names only, on `#2A2A2C` with the selected one on `#3D2826`, at most
/// eight rows around the selection.
final class ConsoleCompletionList: NSView {
    private var names: [String] = []
    private var selected = 0
    private var first = 0
    private static let rows = 8, rowHeight: CGFloat = 30, padding: CGFloat = 4, width: CGFloat = 220

    override var isFlipped: Bool { true }

    func show(_ candidates: [String], selected: Int) {
        names = candidates; self.selected = selected
        // Keep the selection inside the eight rows shown.
        if selected < first { first = selected }
        if selected >= first + Self.rows { first = selected - Self.rows + 1 }
        first = min(first, max(candidates.count - Self.rows, 0))
        isHidden = false; needsDisplay = true
        setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel("Completions")
        setAccessibilityValue(candidates.indices.contains(selected) ? "\(candidates[selected]), \(selected + 1) of \(candidates.count)" : nil)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override var fittingSize: NSSize { NSSize(width: Self.width, height: CGFloat(min(names.count, Self.rows)) * Self.rowHeight + Self.padding * 2) }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ConsoleTheme.list.setFill(); frame.fill()
        ConsoleTheme.listBorder.setStroke(); frame.stroke()
        let font = Tokens.NS.mono(13)
        for (row, index) in (first..<min(first + Self.rows, names.count)).enumerated() {
            let rowRect = NSRect(x: Self.padding, y: Self.padding + CGFloat(row) * Self.rowHeight, width: bounds.width - Self.padding * 2, height: Self.rowHeight)
            if index == selected {
                ConsoleTheme.listSelected.setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5).fill()
            }
            let text = NSAttributedString(string: names[index], attributes: [.font: font, .foregroundColor: ConsoleTheme.command])
            text.draw(at: NSPoint(x: rowRect.minX + 10, y: rowRect.midY - (font.ascender - font.descender) / 2))
        }
    }
}

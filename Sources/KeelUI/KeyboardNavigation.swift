import AppKit
import KeelCore
import SwiftUI

/// Keyboard access to the editors' tables (NFR-AX02): Tab focuses the table, ↑/↓ move the selection a row at a time
/// and scroll it into view, and an accent ring shows where the focus is.
enum RowNavigation {
    /// The row ↑ (`offset` -1) or ↓ (+1) selects: the next one in that direction, staying put at either end; with no
    /// selection (or one filtered out), ↓ starts at the first row and ↑ at the last. Nil without rows.
    static func step<ID: Equatable>(_ ids: [ID], from selected: ID?, by offset: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current = selected.flatMap(ids.firstIndex(of:)) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(max(current + offset, 0), ids.count - 1)]
    }

    static func offset(_ direction: MoveCommandDirection) -> Int? {
        switch direction {
        case .up: -1
        case .down: 1
        default: nil
        }
    }
}

/// ⌃Tab and ⌃⇧Tab leave a text view whose Tab is taken (a character in the value, completion in the console), so no
/// view traps the keyboard focus (NFR-AX02).
enum FocusEscape {
    @MainActor static func handle(_ event: NSEvent?, from view: NSView) -> Bool {
        guard let event, event.type == .keyDown, event.keyCode == tabKeyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control) else { return false }
        if flags.contains(.shift) { view.window?.selectPreviousKeyView(view) } else { view.window?.selectNextKeyView(view) }
        return true
    }

    static let tabKeyCode: UInt16 = 48
}

/// What VoiceOver reads for a row of an editor table: each cell after its column header ("Field city, Value London"),
/// so the columns are heard even though the table is drawn with stacks (NFR-AX01).
enum TableSpeech {
    static func row(_ cells: KeyValuePairs<String, String>, changed: Bool = false) -> String {
        (cells.map { "\($0.key) \($0.value)" } + (changed ? ["changed"] : [])).joined(separator: ", ")
    }
}

extension View {
    /// An accent ring while `visible` (DS-02: focus is accent): the visible focus for views that draw their own.
    func focusRing(_ visible: Bool, cornerRadius: CGFloat = 7) -> some View {
        overlay {
            if visible { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Tokens.accent, lineWidth: 2).allowsHitTesting(false) }
        }
    }

    /// Makes an editor table one Tab stop whose ↑/↓ move the selection through `ids`, scrolling it into view with `proxy`.
    func rowNavigation<ID: Hashable>(_ ids: [ID], selected: ID?, proxy: ScrollViewProxy? = nil, select: @escaping (ID) -> Void) -> some View {
        modifier(RowNavigationModifier(ids: ids, selected: selected, proxy: proxy, select: select))
    }
}

private struct RowNavigationModifier<ID: Hashable>: ViewModifier {
    let ids: [ID]
    let selected: ID?
    let proxy: ScrollViewProxy?
    let select: (ID) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable().focused($focused).focusEffectDisabled()
            .focusRing(focused)
            .onMoveCommand { direction in
                guard let offset = RowNavigation.offset(direction), let id = RowNavigation.step(ids, from: selected, by: offset) else { return }
                select(id)
                proxy?.scrollTo(id)
            }
            .accessibilityHint("Use the up and down arrow keys to select a row")
    }
}

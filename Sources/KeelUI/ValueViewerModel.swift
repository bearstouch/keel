import Combine
import Foundation
import KeelCore

/// The view chosen per key pattern for the session (03 → Value editors): one per tab's browser, in memory only.
@MainActor
public final class ValueViewerChoices {
    private var memory = ValueViewerMemory()
    /// Settings → Editors' default viewer for patterns without a remembered choice; nil picks JSON or Text by value.
    private let defaultMode: ValueViewMode?

    public init(defaultMode: ValueViewMode? = nil) { self.defaultMode = defaultMode }

    func mode(for pattern: Data) -> ValueViewMode? { memory.mode(for: pattern) ?? defaultMode }
    func remember(_ mode: ValueViewMode, for pattern: Data) { memory.remember(mode, for: pattern) }
}

/// The value viewer under an editor (08 Design → Editor): one value or element at a time, its Text / JSON / Hex / Raw
/// view and the user's edits. Large values are prepared off the main actor, so opening or switching never stalls the
/// window (KEEL-028 AC3).
@MainActor
public final class ValueViewerModel: ObservableObject {
    /// Values above this render in the background; smaller ones render at once, without a flash of the spinner.
    static let backgroundThreshold = 64 * 1024

    /// Nil while a large value is being prepared.
    @Published public private(set) var state: ValueViewerState?
    /// The element's name (a hash field, "Value" for a string).
    @Published public private(set) var title = ""
    /// Bumped when `state.text` is replaced by a rendering (open, view switch), not by typing: the text view replaces
    /// its contents only then, so the cursor stays put while the user types.
    @Published public private(set) var revision = 0
    /// Read-only profiles view but never edit (03 → Value editors), nor does a partial load (FR-ED01).
    @Published public internal(set) var isEditable: Bool
    /// After every open, switch and edit: the editor takes `state.bytes` as its draft and refuses Save while
    /// `state.saveBlock` says why.
    var onChange: ((ValueViewerState) -> Void)?

    private let choices: ValueViewerChoices
    /// The open key's pattern (`user:*`), under which a view switch is remembered.
    private let pattern: Data
    /// Bumped by every open and switch, so a background rendering that lands late is dropped.
    private var generation = 0
    /// The background rendering, if one runs; tests await it.
    private(set) var preparation: Task<Void, Never>?

    public init(choices: ValueViewerChoices, pattern: Data, isEditable: Bool) {
        self.choices = choices; self.pattern = pattern; self.isEditable = isEditable
    }

    /// Shows `bytes` in the current view; the first value of an editor takes the pattern's remembered view, or JSON
    /// when it parses, else Text.
    public func open(_ bytes: Data, title: String) {
        self.title = title
        let mode = state?.mode ?? choices.mode(for: pattern)
        prepare(size: bytes.count) { ValueViewerState(bytes: bytes, mode: mode) }
    }

    /// The Text / JSON / Hex / Raw switch; remembered for every key of the pattern this session.
    public func show(_ mode: ValueViewMode) {
        guard let current = state, current.mode != mode else { return }
        choices.remember(mode, for: pattern)
        prepare(size: current.bytes.count) {
            var next = current
            next.show(mode)
            return next
        }
    }

    /// The text view's contents after the user typed.
    public func edit(_ text: String) {
        guard isEditable, var next = state else { return }
        next.edit(text)
        state = next
        onChange?(next)
    }

    private func prepare(size: Int, _ make: @escaping @Sendable () -> ValueViewerState) {
        generation += 1
        let generation = generation
        preparation?.cancel(); preparation = nil
        guard size > Self.backgroundThreshold else { publish(make()); return }
        state = nil
        preparation = Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated, operation: make).value
            guard let self, generation == self.generation else { return }
            self.publish(next)
        }
    }

    private func publish(_ next: ValueViewerState) {
        state = next; revision += 1
        onChange?(next)
    }
}

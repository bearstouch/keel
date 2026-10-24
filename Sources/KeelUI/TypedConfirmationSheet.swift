import KeelCore
import SwiftUI

/// The shared typed-confirmation sheet's state (FR-SF03): multi-key delete, bulk delete, FLUSHDB and FLUSHALL. The
/// action runs only from the destructive button, and only while the field holds the expected text exactly.
@MainActor
public final class TypedConfirmationModel: ObservableObject, Identifiable {
    public let confirmation: TypedConfirmation
    /// Up to `listLimit` names of what is destroyed (the selected keys, FR-KB11), already escaped for display.
    public let listed: [String]
    /// How many more there are than `listed` shows.
    public let unlisted: Int
    @Published public var typed = ""
    @Published public private(set) var isRunning = false
    /// Why the action failed; the sheet stays open to show it.
    @Published public private(set) var failure: String?

    public static let listLimit = 5

    /// Returns why it failed, or nil when done (the sheet then closes).
    private let action: @MainActor () async -> String?

    public init(_ confirmation: TypedConfirmation, names: [String] = [], total: Int? = nil, action: @escaping @MainActor () async -> String?) {
        self.confirmation = confirmation
        listed = Array(names.prefix(Self.listLimit))
        unlisted = max((total ?? names.count) - listed.count, 0)
        self.action = action
    }

    /// Once the action failed it isn't offered again: part of it may have run (a batch whose reply was lost must never be
    /// re-sent), so the user starts over from what is left.
    public var canConfirm: Bool { confirmation.matches(typed) && !isRunning && failure == nil }

    /// Return in the field: it never confirms, whatever was typed (NFR-UX03).
    public func submit() {}

    /// The destructive button. Returns true when the action ran and succeeded.
    @discardableResult
    public func confirm() async -> Bool {
        guard canConfirm else { return false }
        isRunning = true; failure = nil
        defer { isRunning = false }
        failure = await action()
        return failure == nil
    }
}

/// Title, one sentence, the server on production, what is destroyed, the field and two buttons (08 Design → Sheets,
/// 480 wide). The destructive button has no keyboard shortcut and Return in the field does nothing, so only a click
/// (or VoiceOver's press) confirms; Escape cancels.
struct TypedConfirmationSheet: View {
    @ObservedObject var model: TypedConfirmationModel
    let dismiss: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let confirmation = model.confirmation
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.title).font(Tokens.interface(15, weight: .semibold)).foregroundStyle(Tokens.fg)
                .accessibilityAddTraits(.isHeader)
            Text(confirmation.message).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg).fixedSize(horizontal: false, vertical: true)
            if let server = confirmation.serverLine { ProductionServerLine(server: server) }
            if !model.listed.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.listed.enumerated()), id: \.offset) { _, name in
                        Text(name).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
                    }
                    if model.unlisted > 0 {
                        Text("and \(KeyIndexFooter.grouped(model.unlisted)) more").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text(confirmation.prompt).font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg)
            TextField("", text: $model.typed).font(Tokens.mono(12.5)).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().focused($fieldFocused)
                .onSubmit { model.submit() }
                .accessibilityLabel(confirmation.prompt)
            if let failure = model.failure {
                Text(failure).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(model.failure == nil ? "Cancel" : "Close", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction).disabled(model.isRunning)
                Button(role: .destructive) {
                    Task { if await model.confirm() { dismiss() } }
                } label: {
                    Text(model.isRunning ? "\(confirmation.actionTitle)…" : confirmation.actionTitle)
                }
                .tint(Tokens.danger).buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
                .accessibilityHint(model.canConfirm ? "" : confirmation.prompt)
            }
        }
        .padding(.vertical, 28).padding(.horizontal, 32).frame(width: 480)
        .background(Tokens.sheet)
        .onAppear { fieldFocused = true }
    }
}

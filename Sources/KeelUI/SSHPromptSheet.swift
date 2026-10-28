import Foundation
import KeelSSH
import SwiftUI

/// The app's side of the prompt relay (FR-CN07): ssh's questions queue here and are shown one at a time in a sheet.
/// Answers go straight back to the relay; the sheet closes only through its buttons (Escape is Reject, Deny or
/// Cancel), so nothing is ever accepted without a click on Accept, Allow or Continue.
@MainActor
public final class SSHPromptCenter: ObservableObject {
    @Published public private(set) var queue: [SSHPrompt] = []
    private let relay: PromptRelay

    public init(relay: PromptRelay) { self.relay = relay }

    public var current: SSHPrompt? { queue.first }

    /// Starts receiving prompts. Events hop to the main queue in order, so a withdraw never overtakes its show.
    public func attach() async {
        await relay.setPresenter { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
        }
    }

    func receive(_ event: SSHPromptEvent) {
        switch event {
        case .show(let prompt): if !queue.contains(where: { $0.id == prompt.id }) { queue.append(prompt) }
        case .withdraw(let id): queue.removeAll { $0.id == id }
        }
    }

    /// Answers the prompt the user saw, by its ID. An answer for a prompt no longer queued (timed out, tunnel gone) is
    /// dropped: it must never answer the prompt queued behind it, which the user hasn't seen.
    public func respond(to id: UUID, with response: SSHPromptResponse) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index)
        Task { [relay] in await relay.respond(to: id, with: response) }
    }
}

/// One ssh prompt with ssh's own text. Host keys get Reject / Accept with no default button, so Return never trusts a
/// key; Escape always declines.
public struct SSHPromptSheet: View {
    let prompt: SSHPrompt
    let respond: (SSHPromptResponse) -> Void
    @State private var answer = ""

    public init(prompt: SSHPrompt, respond: @escaping (SSHPromptResponse) -> Void) { self.prompt = prompt; self.respond = respond }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(prompt.kind)).font(Tokens.interface(13, weight: .semibold))
                Text(Self.subtitle(prompt)).font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            }
            ScrollView {
                Text(prompt.text)
                    .font(Tokens.mono())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .accessibilityLabel("\(prompt.fromServer ? "The SSH server says" : "ssh says"): \(prompt.text)")
            if Self.takesText(prompt.kind) { field }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(prompt.kind))
    }

    @ViewBuilder private var field: some View {
        let label = Self.fieldLabel(prompt.kind)
        if prompt.echo {
            TextField(label, text: $answer).accessibilityLabel(label)
        } else {
            SecureField(label, text: $answer).accessibilityLabel(label)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch prompt.kind {
        case .hostKey:
            Button("Reject", role: .cancel) { respond(.decline) }.keyboardShortcut(.cancelAction)
            Button("Accept") { respond(.accept) }.accessibilityHint("Trusts this host key and continues connecting")
        case .confirm:
            Button("Deny", role: .cancel) { respond(.decline) }.keyboardShortcut(.cancelAction)
            Button("Allow") { respond(.accept) }
        case .notice:
            Button("Dismiss") { respond(.decline) }.keyboardShortcut(.cancelAction)
        case .password, .passphrase, .code:
            Button("Cancel", role: .cancel) { respond(.decline) }.keyboardShortcut(.cancelAction)
            Button("Continue") {
                respond(.text(Data(answer.utf8))); answer = ""
            }
            .keyboardShortcut(.defaultAction)
            .disabled(answer.isEmpty)
        }
    }

    static func title(_ kind: SSHPrompt.Kind) -> String {
        switch kind {
        case .hostKey: return "Verify the SSH host key"
        case .password: return "SSH password"
        case .passphrase: return "SSH key passphrase"
        case .code: return "SSH verification"
        case .confirm: return "Confirm SSH request"
        case .notice: return "SSH notice"
        }
    }

    /// A keyboard-interactive question is the server's own text; the sheet says so instead of presenting it as ssh's.
    static func subtitle(_ prompt: SSHPrompt) -> String {
        prompt.fromServer ? "Asked by the SSH server \(prompt.destination)" : "ssh to \(prompt.destination)"
    }

    static func takesText(_ kind: SSHPrompt.Kind) -> Bool { [.password, .passphrase, .code].contains(kind) }

    static func fieldLabel(_ kind: SSHPrompt.Kind) -> String {
        switch kind {
        case .passphrase: return "Passphrase"
        case .code: return "Answer"
        default: return "Password"
        }
    }
}

extension View {
    /// Presents `center`'s prompts as sheets over this view.
    public func sshPrompts(_ center: SSHPromptCenter?) -> some View {
        modifier(SSHPromptPresenter(center: center))
    }
}

private struct SSHPromptPresenter: ViewModifier {
    let center: SSHPromptCenter?

    func body(content: Content) -> some View {
        if let center { content.modifier(Presenting(center: center)) } else { content }
    }

    private struct Presenting: ViewModifier {
        @ObservedObject var center: SSHPromptCenter
        @Environment(\.presentsSharedSheets) private var active

        func body(content: Content) -> some View {
            // The setter is a no-op: SwiftUI may write nil while swapping to the next queued prompt, which must not
            // answer it. Every sheet has a cancel-action button, and the sheet can't be dismissed any other way.
            content.sheet(item: Binding(get: { active ? center.current : nil }, set: { _ in })) { prompt in
                SSHPromptSheet(prompt: prompt) { center.respond(to: prompt.id, with: $0) }.id(prompt.id).interactiveDismissDisabled()
            }
        }
    }
}

import AppKit
import KeelCore
import SwiftUI

/// Console mode (08 Design → Console, FR-CO08): the dark pane edge to edge, no header or footer. While a command runs
/// or a stream reads, a small Stop (⌘.) floats at the top right; confirmations are the shared sheets.
struct ConsolePane: View {
    @ObservedObject var console: ConsoleModel
    let session: TabSession

    var body: some View {
        VStack(spacing: 0) {
            ProductionWriteNotice(session: session)
            ConsoleHost(model: console)
                .overlay(alignment: .topTrailing) { ConsoleActivity(console: console).padding(12) }
        }
        .background(Color(nsColor: ConsoleTheme.background))
        .task { await console.start() }
        .sheet(item: $console.typedConfirmation) { confirmation in
            TypedConfirmationSheet(model: confirmation) { console.dismissTypedConfirmation() }
        }
        .alert(console.goAhead?.title ?? "", isPresented: goAheadShown, presenting: console.goAhead) { _ in
            Button("Cancel", role: .cancel) { console.cancelGoAhead() }
            Button("Run") { Task { await console.confirmGoAhead() } }
        } message: { request in
            Text(request.message)
        }
    }

    private var goAheadShown: Binding<Bool> {
        Binding(get: { console.goAhead != nil }, set: { if !$0 { console.cancelGoAhead() } })
    }
}

/// The model's scroll view, made once and kept while the tab lives.
private struct ConsoleHost: NSViewRepresentable {
    let model: ConsoleModel

    func makeNSView(context: Context) -> NSScrollView {
        let view = model.scrollView
        DispatchQueue.main.async { if let text = view.documentView { view.window?.makeFirstResponder(text) } }
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// "Waiting for reply…" or "Streaming" with Stop, only while something runs (FR-CO07).
private struct ConsoleActivity: View {
    @ObservedObject var console: ConsoleModel

    var body: some View {
        if console.state != .idle {
            HStack(spacing: 8) {
                if console.state == .running { ProgressView().controlSize(.mini).tint(Color(nsColor: ConsoleTheme.command)) }
                Text(console.state == .streaming ? "Streaming" : "Waiting for reply…").font(Tokens.interface(12)).foregroundStyle(Color(nsColor: ConsoleTheme.prompt))
                Button {
                    Task { await console.stop() }
                } label: {
                    Text("Stop ⌘.").font(Tokens.interface(12, weight: .semibold)).foregroundStyle(Color(nsColor: ConsoleTheme.command))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color(nsColor: ConsoleTheme.list), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: ConsoleTheme.listBorder)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(console.state == .streaming ? "Stop streaming" : "Stop the command")
            }
            .accessibilityElement(children: .contain)
        }
    }
}

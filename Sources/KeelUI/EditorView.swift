import AppKit
import KeelCore
import SwiftUI

/// The editor area beside the key list (08 Design → Editor): nothing selected, or the open key's shell.
struct EditorArea: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if let editor = browser.editor {
            // A new identity per key, so popovers and alerts of the previous key don't carry over.
            EditorShell(session: editor).id(editor.key)
        } else {
            Text("Select a key to view its value.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Key title (mono), type badge and `⋯`; one metadata line; the type's editor; the floating save bar only while
/// something is unsaved (FR-ED13, 03 → Value editors).
struct EditorShell: View {
    @ObservedObject var session: EditorSession
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            metadata.padding(.top, 6)
            content.padding(.top, 28)
        }
        .padding(.horizontal, 36).padding(.top, 28)
        // Room under the viewer for the floating save bar (48 high, 24 from the bottom) while it shows.
        .padding(.bottom, session.showsSaveBar ? 88 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if session.showsSaveBar { SaveBar(session: session).padding(.horizontal, 36).padding(.bottom, 24) }
        }
        .alert("This key changed since it was loaded", isPresented: conflict) {
            Button("Reload") { Task { await session.reload() } }
            Button("Overwrite", role: .destructive) { Task { await session.overwrite() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing was saved. Reload shows the server's value and drops your changes; Overwrite saves your changes over it.")
        }
    }

    private var conflict: Binding<Bool> {
        Binding(get: { session.phase == .conflict }, set: { if !$0 { session.dismissConflict() } })
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(KeyDisplay.name(session.key)).font(Tokens.mono(20).weight(.semibold)).foregroundStyle(Tokens.fg)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            TypeBadge(type: session.type)
            Spacer(minLength: 0)
            actions
        }
    }

    /// Secondary actions (DS-01). Rename, Set TTL and Delete arrive with KEEL-035; on a read-only profile they stay
    /// disabled whatever is built.
    private var actions: some View {
        Menu {
            Button("Rename…") {}.disabled(true)
            Button("Set TTL…") {}.disabled(true)
            Menu("Copy") {
                Button("Copy Name") { copy(KeyDisplay.name(session.key)) }
                Button("Copy as redis-cli Argument") { copy(KeyDisplay.redisCliArgument(session.key)) }
            }
            Button("Delete…") {}.disabled(true)
            Divider()
            Button("Details…") { showsDetails = true }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(Tokens.muted).frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More actions: rename, TTL, copy, delete, details")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { DetailsPopover(session: session) }
    }

    /// FR-KB10: the display name, or the always-escaped argument that parses back to the same bytes.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            if session.isReadOnly { Image(systemName: "lock").font(.system(size: 10)).accessibilityHidden(true) }
            Text(session.header.metadataLine)
        }
        .font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .loading where session.loaded == nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message).font(Tokens.interface(12.5)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true)
        default:
            if session.showsWholeValue {
                VStack(alignment: .leading, spacing: 10) {
                    if let partial = session.partial { PartialNotice(session: session, partial: partial) }
                    ValueViewerPanel(model: session.viewer)
                }
            } else if session.binding == nil {
                Notice(type: session.type)
            }
        }
    }
}

/// FR-ED01: "Partial (1 MiB of 2 MiB) · Read-only until loaded · Load all", or why the rest can't be loaded. Text, not
/// color, carries the state (NFR-AX01).
private struct PartialNotice: View {
    @ObservedObject var session: EditorSession
    let partial: PartialLoad

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.ellipsis").font(.system(size: 11)).accessibilityHidden(true)
            Text("\(partial.text) · \(status)")
            if partial.canLoadAll {
                Button(session.phase == .loading ? "Loading…" : "Load all") { Task { await session.loadAll() } }
                    .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadAll)
                    .accessibilityHint("Reads the whole value so it can be edited")
            }
            if let failure = session.loadAllFailure { Text(failure).foregroundStyle(Tokens.danger).lineLimit(2) }
        }
        .font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
        .accessibilityElement(children: .contain)
    }

    private var status: String { partial.canLoadAll ? "Read-only until fully loaded" : "Too large to load all (over 64 MiB) · Read-only" }
}

/// FR-ED07 for module types; for core types, the editor isn't in this build yet.
private struct Notice: View {
    let type: KeyType

    var body: some View {
        Text(type == .other ? "No editor for this type." : "Editing this type isn't available in this build yet.")
            .font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
    }
}

/// The type badge as in the key list (08 Design → Type badges).
struct TypeBadge: View {
    let type: KeyType

    var body: some View {
        if let text = KeyListRow.badge(type) {
            let colors = Tokens.NS.badge(type)
            Text(text).font(Tokens.interface(10, weight: .semibold)).tracking(0.4)
                .foregroundStyle(Color(nsColor: colors.fg))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color(nsColor: colors.fill), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel(KeyListRow.spoken(type) ?? text)
        }
    }
}

/// "1 unsaved change · Revert · Save" (⌘Z / ⌘S), floating at the bottom of the editor.
struct SaveBar: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        HStack(spacing: 10) {
            Text(session.saveBlock.map { "\(session.saveBarText) · \($0)" } ?? session.saveBarText).font(Tokens.interface(12.5)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Revert") { session.revert() }
                .buttonStyle(.plain).font(Tokens.interface(12.5)).padding(.horizontal, 14).frame(height: 32)
                .help("Revert (⌘Z)")
            Button {
                Task { await session.save() }
            } label: {
                Text(session.phase == .saving ? "Saving…" : "Save").font(Tokens.interface(12.5, weight: .semibold))
                    .foregroundStyle(Tokens.onAccent).padding(.horizontal, 16).frame(height: 32)
                    .background(Tokens.accent, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).disabled(session.phase == .saving || session.saveBlock != nil).opacity(session.saveBlock == nil ? 1 : 0.5)
            .help(session.saveBlock ?? "Save (⌘S)")
        }
        .foregroundStyle(Tokens.onSaveBar)
        .padding(.leading, 16).padding(.trailing, 8).frame(height: 48)
        .background(Tokens.saveBar, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.saveBlock.map { "\(session.saveBarText). \($0)" } ?? session.saveBarText)
    }
}

/// ⋯ → Details: encoding and exact TTL at once, memory size when asked; "unavailable" when the server won't say.
private struct DetailsPopover: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        let details = session.details ?? KeyDetails()
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Encoding", details.encodingText)
            row("TTL", details.ttlText)
            GridRow {
                Text("Memory").foregroundStyle(Tokens.muted)
                if let memory = details.memoryText {
                    Text(memory).font(Tokens.mono(12)).textSelection(.enabled)
                } else {
                    Button("Measure") { Task { await session.loadDetails(memory: true) } }.buttonStyle(.plain).foregroundStyle(Tokens.accent)
                }
            }
        }
        .font(Tokens.interface(12.5)).foregroundStyle(Tokens.fg)
        .padding(16).frame(minWidth: 260, alignment: .leading)
        .task { await session.loadDetails() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Tokens.muted)
            Text(value).font(Tokens.mono(12)).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

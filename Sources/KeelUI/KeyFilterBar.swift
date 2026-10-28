import AppKit
import KeelCore
import SwiftUI

/// The key list's filters (FR-KB05): a glob pattern and a type, applied by the server (`SCAN … MATCH … TYPE`) and
/// restarting the scan when either changes, plus the quick local filter over the keys already loaded.
@MainActor
public final class KeyFilterModel: ObservableObject {
    /// What the one filter field does: a server pattern, applied on Return, or a substring over loaded keys, live.
    public enum Field: String, Sendable, Equatable { case pattern, local }

    @Published public var field: Field = .pattern
    /// The pattern field's text; it takes effect on Return (`applyPattern`), so typing never restarts the scan.
    @Published public var patternText = ""
    @Published public var localText = ""
    /// The filter the index scans with now.
    @Published public private(set) var applied: KeyFilter
    /// Bumped by ⌘F; the bar focuses its field when it changes.
    @Published public private(set) var focusRequest = 0

    public let list: KeyListDataSource
    /// Loads after a restart; the browser that owns paging replaces it, so Auto-page resumes under the new filter.
    var startScan: @MainActor (KeyIndex) async -> Void
    private var focusObserver: NSObjectProtocol?
    /// The browser's check before a restart closes an editor with unsaved changes (FR-ED16): it runs the restart now
    /// or once the user answers, never on Cancel.
    var confirmsRestart: ((@escaping @MainActor () async -> Void) async -> Void)?

    /// `filter` is the one the index was created with (`KeyIndexConfiguration.filter`).
    public init(list: KeyListDataSource, filter: KeyFilter = KeyFilter(), startScan: @escaping @MainActor (KeyIndex) async -> Void = { _ = await $0.loadMore() }) {
        self.list = list; self.startScan = startScan
        applied = filter
        patternText = applied.pattern.map { String(decoding: $0, as: UTF8.self) } ?? ""
        focusObserver = NotificationCenter.default.addObserver(forName: KeyListCommands.focusFilterNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.focusIfShown(in: window) }
        }
    }

    isolated deinit { focusObserver.map(NotificationCenter.default.removeObserver) }

    /// The type the type menu shows.
    public var type: KeyTypeFilter? { applied.type }

    /// Shown under the field while the type is checked on this Mac (AC4); nil when the server filters.
    public var notice: String? { applied.clientSideNotice }

    /// Return in the pattern field.
    public func applyPattern() async { await apply(KeyFilter(pattern: patternText, type: applied.type)) }

    /// The type menu; nil is "All types". It keeps the applied pattern: text typed without Return stays unapplied.
    public func setType(_ type: KeyTypeFilter?) async { await apply(KeyFilter(pattern: applied.pattern, type: type)) }

    /// Typing in the local field.
    public func setLocalText(_ text: String) async {
        localText = text
        await list.setLocalFilter(text)
    }

    /// Switches the field between the server pattern and the local filter; leaving local mode clears it.
    public func setField(_ field: Field) async {
        guard field != self.field else { return }
        self.field = field
        if field == .pattern { await setLocalText("") }
    }

    /// A changed filter restarts the scan: the loaded keys go at once, so no stale key shows under the new filter
    /// (AC2). The same filter again does nothing; Refresh (⌘R) is how to rescan with it.
    func apply(_ filter: KeyFilter) async {
        guard filter != applied else { return }
        guard let confirmsRestart else { await restart(with: filter); return }
        await confirmsRestart { [weak self] in await self?.restart(with: filter) }
    }

    private func restart(with filter: KeyFilter) async {
        guard filter != applied else { return }
        applied = filter
        await list.index.restart(filter: filter)
        await list.reload()
        // Another change while the list reloaded owns the scan now.
        guard filter == applied else { return }
        await startScan(list.index)
        await list.reload()
    }

    /// ⌘F: focus this window's filter field.
    func focusIfShown(in window: NSWindow?) {
        guard let window, list.scrollView.window === window else { return }
        focusRequest += 1
    }
}

/// The filter field above the key list (08 Design → Key list): one rounded `soft` field with the magnifier, which
/// is also the menu that switches between the server pattern and the local filter; then the type menu and, for
/// patterns, a "?" that opens the glob help. A client-side type filter says so on a quiet line below.
struct KeyFilterBar: View {
    @ObservedObject var model: KeyFilterModel
    @FocusState private var focused: Bool
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fieldMenu
                field
                if model.field == .pattern { helpButton }
                typeMenu
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 8))
            if let notice = model.notice {
                Text(notice)
                    .font(Tokens.interface(11)).foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Note: \(notice)")
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 10, trailing: 16))
        .onChange(of: model.focusRequest) { focused = true }
    }

    private var fieldMenu: some View {
        Menu {
            Picker("Filter", selection: Binding(get: { model.field }, set: { field in Task { await model.setField(field) } })) {
                Text("Server pattern (SCAN MATCH)").tag(KeyFilterModel.Field.pattern)
                Text("Loaded keys (contains)").tag(KeyFilterModel.Field.local)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Tokens.muted)
        .accessibilityLabel("Filter mode")
        .accessibilityValue(model.field == .pattern ? "Server pattern" : "Loaded keys")
    }

    @ViewBuilder private var field: some View {
        switch model.field {
        case .pattern:
            TextField("Filter keys", text: $model.patternText)
                .onSubmit { Task { await model.applyPattern() } }
                .accessibilityLabel("Filter keys by pattern")
                .accessibilityHint("Glob pattern sent to the server; press Return to apply")
                .modifier(FilterFieldStyle(focused: $focused))
        case .local:
            TextField("Filter loaded keys", text: Binding(get: { model.localText }, set: { text in Task { await model.setLocalText(text) } }))
                .accessibilityLabel("Filter loaded keys")
                .accessibilityHint("Shows loaded keys containing this text")
                .modifier(FilterFieldStyle(focused: $focused))
        }
    }

    private var helpButton: some View {
        Button {
            showsHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 12))
        }
        .buttonStyle(.plain).foregroundStyle(Tokens.muted)
        .help("Pattern syntax")
        .accessibilityLabel("Pattern syntax help")
        .popover(isPresented: $showsHelp, arrowEdge: .bottom) { GlobHelp() }
    }

    private var typeMenu: some View {
        Menu {
            Picker("Type", selection: Binding(get: { model.type }, set: { type in Task { await model.setType(type) } })) {
                Text("All types").tag(KeyTypeFilter?.none)
                Divider()
                ForEach(KeyTypeFilter.allCases, id: \.self) { type in Text(type.title).tag(Optional(type)) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(model.type?.rawValue ?? "All types").font(Tokens.interface(11.5))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(model.type == nil ? Tokens.muted : Tokens.fg)
        .accessibilityLabel("Key type filter")
        .accessibilityValue(model.type?.title ?? "All types")
    }
}

private struct FilterFieldStyle: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(Tokens.mono()).foregroundStyle(Tokens.fg).focused(focused)
    }
}

/// The glob help popover: `MATCH` syntax with one example.
private struct GlobHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pattern syntax").font(Tokens.interface(13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(KeyFilter.globHelp, id: \.syntax) { item in
                    GridRow {
                        Text(item.syntax).font(Tokens.mono(12))
                        Text(item.meaning).font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Example: user:* lists every key under user:. The server matches as it scans, so a narrow pattern can take several pages to show its first keys.")
                .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

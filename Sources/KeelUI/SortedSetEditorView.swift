import KeelCore
import SwiftUI

/// The sorted set editor (FR-ED05, 08 Design → Editor): pattern search, the Member / Score table sorted by score (the
/// Score header reverses it) with changed rows marked by an accent dot, "+ Add member", the page line with Load more,
/// and the selected member in the viewer below (read-only).
struct SortedSetEditorView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var model: SortedSetEditorModel
    @State private var adding = false
    @State private var editing: ScoreEdit?

    init(session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: SortedSetEditorModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            table.padding(.top, 12)
            footer.padding(.top, 10)
            if let row = session.viewedRow {
                ValueViewerPanel(model: session.viewer).frame(minHeight: 160).padding(.top, 16).id(row.id)
            }
        }
        .sheet(isPresented: $adding) { AddScoredMemberSheet { member, score in Task { await model.add(member, score: score) } } }
        .sheet(item: $editing) { edit in
            ScoreSheet(edit: edit) { text in
                switch edit.kind {
                case .change: return model.changeScore(edit.member, to: text)
                case .increment:
                    guard SortedSetEditor.parseScore(text) != nil else { return false }
                    Task { await model.increment(edit.member, by: text) }
                    return true
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
            TextField("Search members (pattern, e.g. user:*)", text: $model.pattern).textFieldStyle(.plain)
                .onSubmit { Task { await model.search() } }
                .accessibilityLabel("Search members").accessibilityHint("Press Return to find members matching this pattern on the server")
            if model.searchResults != nil {
                Button {
                    model.pattern = ""; model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(Tokens.interface(12.5)).padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 320)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 7))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Member")
                Spacer(minLength: 12)
                Button {
                    Task { await model.toggleOrder() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Score")
                        Image(systemName: model.descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain).disabled(!model.canToggleOrder)
                .help(model.canToggleOrder ? "Reverses the order" : "Save or revert your changes first")
                .accessibilityLabel("Score, \(model.descending ? "highest" : "lowest") first").accessibilityHint("Reverses the order")
            }
            .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        ScoredRow(
                            row: row, selected: session.selectedRow == row.id, changed: session.changedRows.contains(row.id), writable: session.allowsWrites,
                            canIncrement: model.canRunAction, select: { model.select(row.id) },
                            change: { editing = ScoreEdit(member: row.id, kind: .change, current: String(decoding: row.value, as: UTF8.self)) },
                            increment: { editing = ScoreEdit(member: row.id, kind: .increment, current: "1") }, remove: { model.remove(row.id) })
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if model.rows.isEmpty {
                    Text(emptyText)
                        .font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(12)
                }
            }
            .accessibilityLabel(model.searchResults == nil ? "Members" : "Matching members")
        }
    }

    private var emptyText: String {
        if model.searchResults == nil { return "No members." }
        return model.isSearching ? "Searching…" : "No member matches."
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.allowsWrites {
                Button("+ Add member") { adding = true }.buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!model.canRunAction)
                    .help(model.canRunAction ? "Adds a member at once" : "Save or revert your changes first")
            }
            if let page = model.pageText {
                HStack(spacing: 4) {
                    Text(page).foregroundStyle(Tokens.muted)
                    Text("·").foregroundStyle(Tokens.muted)
                    Button(session.isLoadingMore ? "Loading…" : "Load more") { Task { await session.loadMore() } }
                        .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadMore)
                        .accessibilityHint("Loads the next \(SortedSetEditor.pageSize) members by score")
                }
            } else if let results = model.searchResults {
                HStack(spacing: 4) {
                    Text("\(KeyIndexFooter.grouped(results.count)) matching").foregroundStyle(Tokens.muted)
                    if model.searchNext != nil {
                        Text("·").foregroundStyle(Tokens.muted)
                        Button(model.isSearching ? "Searching…" : "Search more") { Task { await model.searchMore() } }
                            .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(model.isSearching)
                    }
                }
            }
            if let failure = model.failure ?? session.actionFailure ?? session.loadMoreFailure {
                Text(failure).foregroundStyle(Tokens.danger).lineLimit(2)
            } else if let notice = model.notice {
                Text(notice).foregroundStyle(Tokens.muted).lineLimit(2)
            }
        }
        .font(Tokens.interface(12.5))
    }
}

/// Change Score… (a draft edit) or Increment… (runs at once) for one member.
private struct ScoreEdit: Identifiable {
    enum Kind { case change, increment }
    let member: Data
    let kind: Kind
    let current: String
    var id: String { "\(kind)" + member.base64EncodedString() }
}

/// One member (mono, escaped like key names) with the changed dot, and its score right-aligned in full precision;
/// click selects, ⌃-click changes, increments or removes.
private struct ScoredRow: View {
    let row: EditorRow
    let selected: Bool
    let changed: Bool
    let writable: Bool
    let canIncrement: Bool
    let select: () -> Void
    let change: () -> Void
    let increment: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Text(Self.preview(row.id)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.tail)
                if changed { Circle().fill(Tokens.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
            }
            Spacer(minLength: 0)
            Text(score).foregroundStyle(Tokens.muted).lineLimit(1).textSelection(.enabled)
        }
        .font(Tokens.mono(12.5)).padding(.horizontal, 12).frame(height: 40)
        .background(background)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hairSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Change Score…", action: change).disabled(!writable)
            Button("Increment…", action: increment).disabled(!writable || !canIncrement)
            Button("Remove Member", role: .destructive, action: remove).disabled(!writable)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.preview(row.id)), score \(score)\(changed ? ", changed" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Change Score", change)
        .accessibilityAction(named: "Increment", increment)
        .accessibilityAction(named: "Remove Member", remove)
    }

    private var score: String { String(decoding: row.value, as: UTF8.self) }

    private var background: Color {
        if selected { return Tokens.selection }
        return changed ? Tokens.changedRow : .clear
    }

    /// The member on one line: escaped like key names, so newlines and control bytes stay visible.
    static func preview(_ member: Data) -> String {
        let limit = 256
        return member.count > limit ? KeyDisplay.name(member.prefix(limit)) + "…" : KeyDisplay.name(member)
    }
}

/// The score (or the amount to add) as text; Done stays disabled until it parses.
private struct ScoreSheet: View {
    let edit: ScoreEdit
    let apply: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.kind == .change ? "Change Score" : "Increment Score").font(Tokens.interface(15, weight: .semibold))
            Text(KeyDisplay.name(edit.member)).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
            TextField(edit.kind == .change ? "Score" : "Amount", text: $text).font(Tokens.mono(12.5))
                .accessibilityLabel(edit.kind == .change ? "New score" : "Amount to add")
            Text("A number, inf or -inf.").font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.kind == .change ? "Change" : "Increment") {
                    if apply(text) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(SortedSetEditor.parseScore(text) == nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
        .onAppear { text = edit.current }
    }
}

/// "+ Add member": the member as text (UTF-8) and its score.
private struct AddScoredMemberSheet: View {
    let add: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var member = ""
    @State private var score = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Member").font(Tokens.interface(15, weight: .semibold))
            TextField("Member", text: $member, axis: .vertical).lineLimit(1...6).font(Tokens.mono(12.5)).accessibilityLabel("Member")
            TextField("Score", text: $score).font(Tokens.mono(12.5)).accessibilityLabel("Score")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(Data(member.utf8), score); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(member.isEmpty || SortedSetEditor.parseScore(score) == nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
    }
}

import KeelCore
import SwiftUI

/// The list editor (FR-ED03, 08 Design → Editor): "Jump to index", the Index / Value table with the selected item in
/// the viewer below and changed items marked by an accent dot, "+ Push" and "Pop" menus, and the page line with Load
/// more. ⌃-click an item to insert before or after it, or delete it.
struct ListEditorView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var model: ListEditorModel
    @State private var jumpText = ""
    @State private var entry: ValueEntry?

    init(session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: ListEditorModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            jumpField
            table.padding(.top, 12)
            footer.padding(.top, 10)
            if let row = session.viewedRow {
                ValueViewerPanel(model: session.viewer).frame(minHeight: 160).padding(.top, 16).id(row.id)
            }
        }
        .sheet(item: $entry) { entry in
            AddItemSheet(title: entry.title) { value in
                Task {
                    switch entry.kind {
                    case .push(let atHead): await model.push(value, atHead: atHead)
                    case .insert(let id, let before): await model.insert(value, relativeTo: id, before: before)
                    }
                }
            }
        }
        .alert(popTitle, isPresented: Binding(get: { model.pendingPop != nil }, set: { if !$0 { model.cancelPop() } })) {
            Button("Pop", role: .destructive) { Task { await model.confirmPop() } }
            Button("Cancel", role: .cancel) { model.cancelPop() }
        } message: {
            Text("This is a production connection. The item is removed from the list at once.")
        }
    }

    private var popTitle: String { model.pendingPop == false ? "Pop the last item?" : "Pop the first item?" }

    private var jumpField: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.to.line").font(.system(size: 11)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
            TextField("Jump to index", text: $jumpText).textFieldStyle(.plain)
                .onSubmit { Task { await model.jump(to: jumpText) } }
                .accessibilityLabel("Jump to index").accessibilityHint("Loads the page starting at this index; the first item is 0")
        }
        .font(Tokens.interface(12.5)).padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 200)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 7))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Index").frame(width: 90, alignment: .leading).accessibilityAddTraits(.isHeader)
                Text("Value").accessibilityAddTraits(.isHeader)
            }
            .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            ItemRow(
                                row: row, selected: session.selectedRow == row.id, changed: session.changedRows.contains(row.id), writable: session.allowsWrites,
                                canAct: model.canAct, select: { session.select(row.id) },
                                insert: { before in entry = ValueEntry(kind: .insert(id: row.id, before: before)) }, delete: { model.delete(row.id) })
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if model.rows.isEmpty { Text("No items.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(12) }
                }
                .rowNavigation(model.rows.map(\.id), selected: session.selectedRow, proxy: proxy) { session.select($0) }
                .accessibilityLabel("Items")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.allowsWrites {
                Menu("+ Push") {
                    Button("Push to Head…") { entry = ValueEntry(kind: .push(atHead: true)) }
                    Button("Push to Tail…") { entry = ValueEntry(kind: .push(atHead: false)) }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Tokens.accent).disabled(!model.canAct)
                .accessibilityLabel("Push an item").accessibilityHint(model.canAct ? "" : "Save or revert your changes first")
                Menu("Pop") {
                    Button("Pop Head") { Task { await model.pop(atHead: true) } }
                    Button("Pop Tail") { Task { await model.pop(atHead: false) } }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!model.canAct)
                .accessibilityLabel("Pop an item").accessibilityHint(model.canAct ? "" : "Save or revert your changes first")
            }
            if let page = model.pageText {
                HStack(spacing: 4) {
                    Text(page).foregroundStyle(Tokens.muted)
                    if session.hasMore {
                        Text("·").foregroundStyle(Tokens.muted)
                        Button(session.isLoadingMore ? "Loading…" : "Load more") { Task { await session.loadMore() } }
                            .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadMore)
                            .accessibilityHint("Loads the next \(ListEditor.pageSize) items")
                    }
                }
            }
            if let failure = model.message ?? session.actionFailure ?? session.loadMoreFailure {
                Text(failure).foregroundStyle(Tokens.danger).lineLimit(2)
            }
        }
        .font(Tokens.interface(12.5))
    }
}

/// What the value sheet adds: a push at one end, or an insert beside an item.
private struct ValueEntry: Identifiable {
    enum Kind {
        case push(atHead: Bool)
        case insert(id: Data, before: Bool)
    }

    let kind: Kind
    let id = UUID()

    var title: String {
        switch kind {
        case .push(let atHead): return atHead ? "Push to Head" : "Push to Tail"
        case .insert(let id, let before): return "Insert \(before ? "Before" : "After") Index \(KeyDisplay.name(id))"
        }
    }
}

/// One item: index (muted mono) with the changed dot, the value's first line; click selects, ⌃-click inserts or deletes.
private struct ItemRow: View {
    let row: EditorRow
    let selected: Bool
    let changed: Bool
    let writable: Bool
    let canAct: Bool
    let select: () -> Void
    let insert: (_ before: Bool) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(KeyDisplay.name(row.id)).foregroundStyle(Tokens.muted).lineLimit(1)
                if changed { Circle().fill(Tokens.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
            }
            .frame(width: 90, alignment: .leading)
            Text(Self.preview(row.value)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Tokens.mono(12.5)).padding(.horizontal, 12).frame(height: 40)
        .background(background)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hairSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Insert Before…") { insert(true) }.disabled(!canAct)
            Button("Insert After…") { insert(false) }.disabled(!canAct)
            Divider()
            Button("Delete Item", role: .destructive, action: delete).disabled(!writable)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TableSpeech.row(["Index": KeyDisplay.name(row.id), "Value": Self.preview(row.value)], changed: changed))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Insert Before") { if canAct { insert(true) } }
        .accessibilityAction(named: "Insert After") { if canAct { insert(false) } }
        .accessibilityAction(named: "Delete Item") { if writable { delete() } }
    }

    private var background: Color {
        if selected { return Tokens.selection }
        return changed ? Tokens.changedRow : .clear
    }

    /// The value's start on one line, escaped like key names.
    static func preview(_ value: Data) -> String {
        let limit = 256
        return value.count > limit ? KeyDisplay.name(value.prefix(limit)) + "…" : KeyDisplay.name(value)
    }
}

/// Push or insert: the value as text (UTF-8); larger or binary values are edited in the viewer afterwards.
private struct AddItemSheet: View {
    let title: String
    let add: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Tokens.interface(15, weight: .semibold))
            TextField("Value", text: $value, axis: .vertical).lineLimit(3...8).font(Tokens.mono(12.5)).accessibilityLabel("Value")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(Data(value.utf8)); dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
    }
}

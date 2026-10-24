import KeelCore
import SwiftUI

/// The hash editor (FR-ED02, 08 Design → Editor): filter, the Field / Value table with the selected row in `selection`
/// and changed rows marked by an accent dot, "+ Add field", the page line with Load more, and the selected field's
/// value in the viewer below.
struct HashEditorView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var model: HashEditorModel
    @State private var adding = false
    @State private var renaming: Data?

    init(session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: HashEditorModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterField
            table.padding(.top, 12)
            footer.padding(.top, 10)
            if let row = session.viewedRow {
                ValueViewerPanel(model: session.viewer).frame(minHeight: 160).padding(.top, 16).id(row.id)
            }
        }
        .sheet(isPresented: $adding) { AddFieldSheet { field, value in Task { await model.add(field: field, value: value) } } }
        .sheet(item: Binding(get: { renaming.map(RenameTarget.init) }, set: { renaming = $0?.field })) { target in
            RenameFieldSheet(field: target.field) { newField in Task { await model.rename(target.field, to: newField) } }
        }
        .alert(overwriteTitle, isPresented: Binding(get: { model.pendingOverwrite != nil }, set: { if !$0 { model.cancelOverwrite() } })) {
            Button("Replace", role: .destructive) { model.confirmOverwrite() }
            Button("Cancel", role: .cancel) { model.cancelOverwrite() }
        } message: {
            Text("A field with this name already exists. Its value is replaced when you save.")
        }
    }

    private var overwriteTitle: String { model.pendingOverwrite.map { "Replace the field “\(KeyDisplay.name($0.field))”?" } ?? "" }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
            TextField("Filter loaded fields", text: $model.filter).textFieldStyle(.plain)
                .accessibilityLabel("Filter loaded fields").accessibilityHint("Shows loaded fields whose name contains this text")
        }
        .font(Tokens.interface(12.5)).padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 280)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 7))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button(action: model.toggleOrder) {
                    HStack(spacing: 4) {
                        Text("Field")
                        Image(systemName: model.order == .ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain).frame(width: 200, alignment: .leading)
                .accessibilityLabel("Field, sorted \(model.order == .ascending ? "ascending" : "descending")").accessibilityHint("Reverses the order")
                .accessibilityAddTraits(.isHeader)
                Text("Value").accessibilityAddTraits(.isHeader)
            }
            .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            FieldRow(
                                row: row, selected: session.selectedRow == row.id, changed: session.changedRows.contains(row.id), writable: session.allowsWrites,
                                select: { session.select(row.id) }, rename: { renaming = row.id }, delete: { model.delete(row.id) })
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if model.rows.isEmpty {
                        Text(model.filter.isEmpty ? "No fields." : "No loaded field matches.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(12)
                    }
                }
                .rowNavigation(model.rows.map(\.id), selected: session.selectedRow, proxy: proxy) { session.select($0) }
                .accessibilityLabel("Fields")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.allowsWrites {
                Button("+ Add field") { adding = true }.buttonStyle(.plain).foregroundStyle(Tokens.accent)
            }
            if let page = model.pageText {
                HStack(spacing: 4) {
                    Text(page).foregroundStyle(Tokens.muted)
                    Text("·").foregroundStyle(Tokens.muted)
                    Button(session.isLoadingMore ? "Loading…" : "Load more") { Task { await session.loadMore() } }
                        .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadMore)
                        .accessibilityHint("Loads the next \(HashEditor.pageSize) fields")
                }
            }
            if let failure = model.message ?? session.loadMoreFailure {
                Text(failure).foregroundStyle(Tokens.danger).lineLimit(2)
            }
        }
        .font(Tokens.interface(12.5))
    }
}

private struct RenameTarget: Identifiable {
    let field: Data
    var id: Data { field }
}

/// One field: name (muted mono) with the changed dot, the value's first line; click selects, ⌃-click renames or deletes.
private struct FieldRow: View {
    let row: EditorRow
    let selected: Bool
    let changed: Bool
    let writable: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(KeyDisplay.name(row.id)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
                if changed { Circle().fill(Tokens.accent).frame(width: 6, height: 6).accessibilityHidden(true) }
            }
            .frame(width: 200, alignment: .leading)
            Text(Self.preview(row.value)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Tokens.mono(12.5)).padding(.horizontal, 12).frame(height: 40)
        .background(background)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hairSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Rename Field…", action: rename).disabled(!writable)
            Button("Delete Field", role: .destructive, action: delete).disabled(!writable)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TableSpeech.row(["Field": KeyDisplay.name(row.id), "Value": Self.preview(row.value)], changed: changed))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Rename Field", rename)
        .accessibilityAction(named: "Delete Field", delete)
    }

    private var background: Color {
        if selected { return Tokens.selection }
        return changed ? Tokens.changedRow : .clear
    }

    /// The value's start on one line: escaped like key names, so newlines and control bytes stay visible.
    static func preview(_ value: Data) -> String {
        let limit = 256
        return value.count > limit ? KeyDisplay.name(value.prefix(limit)) + "…" : KeyDisplay.name(value)
    }
}

/// "+ Add field": name and value as text (UTF-8); larger or binary values are edited in the viewer afterwards.
private struct AddFieldSheet: View {
    let add: (Data, Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var field = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Field").font(Tokens.interface(15, weight: .semibold))
            TextField("Field", text: $field).font(Tokens.mono(12.5)).accessibilityLabel("Field name")
            TextField("Value", text: $value, axis: .vertical).lineLimit(3...8).font(Tokens.mono(12.5)).accessibilityLabel("Value")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(Data(field.utf8), Data(value.utf8)); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(field.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
    }
}

/// Rename Field…: the new name as text. A name that isn't valid UTF-8 starts empty rather than escaped, so the escape
/// text is never mistaken for the bytes.
private struct RenameFieldSheet: View {
    let field: Data
    let rename: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Field").font(Tokens.interface(15, weight: .semibold))
            Text(KeyDisplay.name(field)).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
            TextField("New name", text: $name).font(Tokens.mono(12.5)).accessibilityLabel("New field name")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    rename(Data(name.utf8)); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
        .onAppear {
            let text = String(decoding: field, as: UTF8.self)
            if Data(text.utf8) == field { name = text }
        }
    }
}

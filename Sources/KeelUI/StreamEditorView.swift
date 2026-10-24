import KeelCore
import SwiftUI

/// The stream viewer (FR-ED06, 08 Design → Editor): the read-only ID / Fields table, newest first (the ID header reverses
/// it), "+ Add entry", the page line with Load more, and the selected entry's fields with the chosen value in the viewer.
struct StreamEditorView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var model: StreamEditorModel
    @State private var adding = false

    init(session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: StreamEditorModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            table
            footer.padding(.top, 10)
            if model.selectedEntry != nil { fields.padding(.top, 16) }
            if let field = model.selectedField, let entry = model.selectedEntry {
                ValueViewerPanel(model: session.viewer).frame(minHeight: 160).padding(.top, 12).id("\(KeyDisplay.name(entry))#\(field)")
            }
        }
        .sheet(isPresented: $adding) { AddEntrySheet { id, fields in Task { await model.add(id: id, fields: fields) } } }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    Task { await model.toggleOrder() }
                } label: {
                    HStack(spacing: 4) {
                        Text("ID")
                        Image(systemName: model.newestFirst ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain).disabled(!model.canToggleOrder)
                .help(model.newestFirst ? "Newest first; click for oldest first" : "Oldest first; click for newest first")
                .accessibilityLabel("ID, \(model.newestFirst ? "newest" : "oldest") first").accessibilityHint("Reverses the order")
                .frame(width: EntryRow.idWidth, alignment: .leading)
                Text("Fields")
                Spacer(minLength: 0)
            }
            .font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        EntryRow(row: row, selected: model.selectedEntry == row.id) { model.select(row.id) }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if model.rows.isEmpty { Text("No entries.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(12) }
            }
            .accessibilityLabel("Entries")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.allowsWrites {
                Button("+ Add entry") { adding = true }.buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!model.canAdd)
                    .help("Appends an entry with XADD")
            }
            if let page = model.pageText {
                HStack(spacing: 4) {
                    Text(page).foregroundStyle(Tokens.muted)
                    Text("·").foregroundStyle(Tokens.muted)
                    Button(session.isLoadingMore ? "Loading…" : "Load more") { Task { await session.loadMore() } }
                        .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadMore)
                        .accessibilityHint("Loads the next \(StreamEditor.pageSize) entries")
                }
            }
            if let failure = model.failure ?? session.actionFailure ?? session.loadMoreFailure {
                Text(failure).foregroundStyle(Tokens.danger).lineLimit(2)
            }
        }
        .font(Tokens.interface(12.5))
    }

    /// The selected entry's fields; clicking one shows its value in the viewer.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fields of \(model.selectedEntry.map(KeyDisplay.name) ?? "")").font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
                .padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(Array(model.selectedFields.enumerated()), id: \.offset) { index, field in
                let selected = model.selectedField == index
                HStack(spacing: 12) {
                    Text(EntryRow.preview(field.field)).foregroundStyle(Tokens.fg).frame(width: EntryRow.idWidth - 12, alignment: .leading)
                    Text(EntryRow.preview(field.value)).foregroundStyle(Tokens.muted)
                    Spacer(minLength: 0)
                }
                .font(Tokens.mono(12)).lineLimit(1).truncationMode(.tail).padding(.horizontal, 12).frame(height: 28)
                .background(selected ? Tokens.selection : .clear)
                .contentShape(Rectangle())
                .onTapGesture { model.selectField(index) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(EntryRow.preview(field.field)): \(EntryRow.preview(field.value))")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// One entry: its ID and its fields on one line (`field=value · …`, mono, escaped like key names). Read-only (AC3).
private struct EntryRow: View {
    static let idWidth: CGFloat = 220
    let row: EditorRow
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(KeyDisplay.name(row.id)).foregroundStyle(Tokens.fg).frame(width: Self.idWidth, alignment: .leading)
            Text(summary).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Tokens.mono(12.5)).lineLimit(1).padding(.horizontal, 12).frame(height: 40)
        .background(selected ? Tokens.selection : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hairSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(KeyDisplay.name(row.id)), \(summary)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The first fields, enough to fill a row; the rest is in the selected entry's field list.
    private var summary: String {
        let fields = StreamEditor.fields(of: row) ?? []
        return fields.prefix(8).map { "\(Self.preview($0.field))=\(Self.preview($0.value))" }.joined(separator: " · ") + (fields.count > 8 ? " · …" : "")
    }

    /// Bytes on one line: escaped like key names, so newlines and control bytes stay visible.
    static func preview(_ bytes: Data) -> String {
        let limit = 120
        return bytes.count > limit ? KeyDisplay.name(bytes.prefix(limit)) + "…" : KeyDisplay.name(bytes)
    }
}

/// "+ Add entry": an automatic (`*`) or explicit ID and field/value rows (text, UTF-8).
private struct AddEntrySheet: View {
    let add: (Data, [DataOperation.FieldValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var automaticID = true
    @State private var id = ""
    @State private var pairs: [Pair] = [Pair()]

    private struct Pair: Identifiable {
        let id = UUID()
        var field = ""
        var value = ""
    }

    var body: some View {
        let problem = StreamEditorModel.problem(id: entryID, fields: fieldValues)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Entry").font(Tokens.interface(15, weight: .semibold))
            Picker("ID", selection: $automaticID) {
                Text("Automatic (*)").tag(true)
                Text("Explicit").tag(false)
            }
            .pickerStyle(.segmented).font(Tokens.interface(12.5))
            if !automaticID {
                TextField("ID, e.g. 1700000000000-0", text: $id).font(Tokens.mono(12.5)).accessibilityLabel("Entry ID")
            }
            ForEach($pairs) { $pair in
                HStack(spacing: 8) {
                    TextField("Field", text: $pair.field).font(Tokens.mono(12.5)).accessibilityLabel("Field name")
                    TextField("Value", text: $pair.value).font(Tokens.mono(12.5)).accessibilityLabel("Value")
                    Button {
                        pairs.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Tokens.muted)
                    }
                    .buttonStyle(.plain).disabled(pairs.count == 1).accessibilityLabel("Remove field")
                }
            }
            Button("+ Add field") { pairs.append(Pair()) }.buttonStyle(.plain).foregroundStyle(Tokens.accent).font(Tokens.interface(12.5))
            if let problem {
                Text(problem).font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(entryID, fieldValues); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 480)
    }

    private var entryID: Data { automaticID ? StreamEditor.autoID : Data(id.trimmingCharacters(in: .whitespaces).utf8) }
    private var fieldValues: [DataOperation.FieldValue] { pairs.map { DataOperation.FieldValue(field: Data($0.field.utf8), value: Data($0.value.utf8)) } }
}

import KeelCore
import SwiftUI

/// The set editor (FR-ED04, 08 Design → Editor): filter, the member list sorted by name with the selected member in the
/// viewer below (read-only) and removed members counted by the save bar, "+ Add member", and the page line with Load more.
struct SetEditorView: View {
    @ObservedObject var session: EditorSession
    @StateObject private var model: SetEditorModel
    @State private var adding = false

    init(session: EditorSession) {
        self.session = session
        _model = StateObject(wrappedValue: SetEditorModel(session: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterField
            list.padding(.top, 12)
            footer.padding(.top, 10)
            if let row = session.viewedRow {
                ValueViewerPanel(model: session.viewer).frame(minHeight: 160).padding(.top, 16).id(row.id)
            }
        }
        .sheet(isPresented: $adding) { AddMemberSheet { member in Task { await model.add(member) } } }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
            TextField("Filter loaded members", text: $model.filter).textFieldStyle(.plain)
                .accessibilityLabel("Filter loaded members").accessibilityHint("Shows loaded members that contain this text")
        }
        .font(Tokens.interface(12.5)).padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 280)
        .background(Tokens.soft, in: RoundedRectangle(cornerRadius: 7))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Member").font(Tokens.interface(11.5)).foregroundStyle(Tokens.muted).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        MemberRow(
                            member: row.id, selected: session.selectedRow == row.id, writable: session.allowsWrites, select: { session.select(row.id) },
                            remove: { model.remove(row.id) })
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if model.rows.isEmpty {
                    Text(model.filter.isEmpty ? "No members." : "No loaded member matches.").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted).padding(12)
                }
            }
            .accessibilityLabel("Members")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.allowsWrites {
                Button("+ Add member") { adding = true }.buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!model.canAdd)
                    .help(model.canAdd ? "Adds a member at once" : "Save or revert your changes first")
            }
            if let page = model.pageText {
                HStack(spacing: 4) {
                    Text(page).foregroundStyle(Tokens.muted)
                    Text("·").foregroundStyle(Tokens.muted)
                    Button(session.isLoadingMore ? "Loading…" : "Load more") { Task { await session.loadMore() } }
                        .buttonStyle(.plain).foregroundStyle(Tokens.accent).disabled(!session.canLoadMore)
                        .accessibilityHint("Loads the next \(SetEditor.pageSize) members")
                }
            }
            if let failure = session.actionFailure ?? session.loadMoreFailure {
                Text(failure).foregroundStyle(Tokens.danger).lineLimit(2)
            } else if let notice = model.notice {
                Text(notice).foregroundStyle(Tokens.muted).lineLimit(2)
            }
        }
        .font(Tokens.interface(12.5))
    }
}

/// One member (mono, escaped like key names); click selects, ⌃-click removes. Removed members leave the list until saved.
private struct MemberRow: View {
    let member: Data
    let selected: Bool
    let writable: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.preview(member)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(Tokens.mono(12.5)).padding(.horizontal, 12).frame(height: 40)
        .background(selected ? Tokens.selection : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hairSoft).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu { Button("Remove Member", role: .destructive, action: remove).disabled(!writable) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.preview(member))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Remove Member", remove)
    }

    /// The member on one line: escaped like key names, so newlines and control bytes stay visible.
    static func preview(_ member: Data) -> String {
        let limit = 256
        return member.count > limit ? KeyDisplay.name(member.prefix(limit)) + "…" : KeyDisplay.name(member)
    }
}

/// "+ Add member": the member as text (UTF-8).
private struct AddMemberSheet: View {
    let add: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var member = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Member").font(Tokens.interface(15, weight: .semibold))
            TextField("Member", text: $member, axis: .vertical).lineLimit(1...6).font(Tokens.mono(12.5)).accessibilityLabel("Member")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    add(Data(member.utf8)); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(member.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
    }
}

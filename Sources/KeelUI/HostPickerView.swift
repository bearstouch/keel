import KeelSSH
import SwiftUI

/// The saved-host part of the SSH tunnel section (FR-CN06): one menu of saved hosts and `~/.ssh/config` aliases,
/// Add / Edit beside it, and a muted line per thing discovery couldn't list (an unfollowed `Include`).
struct HostPickerSection: View {
    @ObservedObject var sheet: ConnectionSheetModel
    @ObservedObject var hosts: HostPickerModel
    @State private var editor: HostEditorModel?

    var body: some View {
        let chosen = hosts.host(sheet.tunnelHostID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("SSH host", selection: selection) {
                    Text("Choose…").tag(String?.none)
                    if !hosts.saved.isEmpty {
                        Section("Saved hosts") {
                            ForEach(hosts.saved) { host in Text(host.name).tag(Optional(HostPickerModel.Entry.saved(host).id)) }
                        }
                    }
                    if !hosts.discovered.isEmpty {
                        Section("From ~/.ssh/config") {
                            ForEach(hosts.discovered, id: \.self) { alias in Text(alias).tag(Optional(HostPickerModel.Entry.discovered(alias: alias).id)) }
                        }
                    }
                }
                .accessibilityHint("Saved SSH hosts and aliases from your SSH config")
                Button("Add…") { editor = HostEditorModel(mode: .create, library: hosts.library) }
                    .accessibilityLabel("Add an SSH host")
                if let host = chosen {
                    Button("Edit…") { editor = HostEditorModel(mode: .edit(host), library: hosts.library) }
                        .accessibilityLabel("Edit SSH host \(host.name)")
                }
            }
            if let host = chosen {
                Text(Self.detail(host)).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
            }
            ForEach(hosts.notes, id: \.self) { note in Text(note).font(Tokens.interface(12)).foregroundStyle(Tokens.muted) }
            if let error = hosts.error { Text(error).font(Tokens.interface(12)).foregroundStyle(Tokens.danger) }
        }
        .sheet(item: $editor) { editor in
            HostEditorSheet(model: editor) { saved in
                self.editor = nil
                Task {
                    await hosts.reload()
                    if let saved { await sheet.useHost(.saved(saved)) }
                }
            }
            .interactiveDismissDisabled()
        }
    }

    /// The menu's selection is an entry id; choosing an alias saves it before the profile points at it.
    private var selection: Binding<String?> {
        Binding(
            get: { hosts.host(sheet.tunnelHostID).map { HostPickerModel.Entry.saved($0).id } },
            set: { id in
                guard let id else { Task { await sheet.useHost(nil) }; return }
                guard let entry = hosts.entries.first(where: { $0.id == id }) else { return }
                Task { await sheet.useHost(entry) }
            })
    }

    /// `user@destination:port · key`, what ssh will be asked for; the password is only ever "saved".
    static func detail(_ host: SavedHost) -> String {
        var text = (host.user.map { "\($0)@" } ?? "") + host.destination + (host.port.map { ":\($0)" } ?? "")
        if let key = host.identityFile { text += " · \((key as NSString).lastPathComponent)" }
        if let policy = host.savedPassword { text += policy.requiresUserPresence ? " · password (Touch ID)" : " · password" }
        return text
    }
}

/// Add / Edit SSH Host: name, destination, user, port, identity file, then the write-only password and its Touch ID
/// option. Return saves and Escape cancels.
struct HostEditorSheet: View {
    @ObservedObject var model: HostEditorModel
    let done: (SavedHost?) -> Void
    @State private var pickingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.title).font(Tokens.interface(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { field(.name, SheetTextField(label: "Name", placeholder: model.destination, text: $model.name)).gridCellColumns(4) }
                GridRow {
                    field(.destination, SheetTextField(label: "Destination", placeholder: "alias or host name", text: $model.destination, mono: true)).gridCellColumns(3)
                    field(.port, SheetTextField(label: "Port", placeholder: "22", text: $model.port, mono: true))
                }
                GridRow {
                    field(.user, SheetTextField(label: "User", placeholder: "from ~/.ssh/config", text: $model.user)).gridCellColumns(2)
                    field(
                        .identityFile,
                        HStack(alignment: .bottom, spacing: 8) {
                            SheetTextField(label: "Identity file", placeholder: "default", text: $model.identityFile, mono: true)
                            Button("Choose…") { pickingKey = true }.accessibilityLabel("Choose an SSH identity file")
                        }
                    )
                    .gridCellColumns(2)
                }
            }
            passwordField
            footer
        }
        .foregroundStyle(Tokens.fg)
        .padding(.vertical, 24).padding(.horizontal, 28)
        .frame(width: 480)
        .background(Tokens.sheet)
        .fileImporter(isPresented: $pickingKey, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.identityFile = url.path }
        }
        .onChange(of: model.finished) { if let finished = model.finished { done(finished) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SSH password · saved in Keychain").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            // A saved password is never shown: the field only takes a replacement.
            SecureField(
                "", text: $model.password,
                prompt: Text(model.hasSavedPassword && !model.removePassword ? "Saved — type to replace" : "Optional").foregroundStyle(Tokens.muted.opacity(0.7))
            )
            .modifier(FieldStyle(mono: false))
            .accessibilityLabel("SSH password, saved in Keychain")
            .accessibilityValue(model.hasSavedPassword && model.password.isEmpty ? "Saved" : "")
            if let message = model.fieldErrors[.password] { Text(message).font(Tokens.interface(12)).foregroundStyle(Tokens.danger) }
            if model.hasSavedPassword || !model.password.isEmpty {
                Toggle("Require Touch ID to use the password", isOn: $model.requiresUserPresence).font(Tokens.interface(12)).toggleStyle(.checkbox)
                    .accessibilityHint("Touch ID or your Mac password is asked for before each tunnel uses it")
            }
            if model.hasSavedPassword {
                Toggle("Remove saved password", isOn: $model.removePassword).font(Tokens.interface(12)).toggleStyle(.checkbox)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.saveError {
                Text(error).font(Tokens.interface(12.5)).foregroundStyle(Tokens.danger).accessibilityLabel("Couldn't save: \(error)")
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }.buttonStyle(SheetButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.save() } }
                    .buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving || model.destination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// A field with its validation message below it.
    private func field(_ key: HostField, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            if let message = model.fieldErrors[key] { Text(message).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

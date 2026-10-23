import AppKit
import KeelCore
import KeelSSH
import SwiftUI
import UniformTypeIdentifiers

/// The New / Edit Connection sheet (FR-CN19, 08 Design → Sheets; boards `Connection` / `ConnectionDark`): URL, Name,
/// Host and Port, Username and Password, label dots, Read-only, then the collapsed TLS / SSH tunnel / Advanced rows,
/// and the footer Test · Cancel · Save. Return saves and Escape cancels; every field has a label.
public struct ConnectionSheet: View {
    @ObservedObject var model: ConnectionSheetModel
    @State private var picking: FilePick?

    private enum FilePick: Identifiable {
        case caFile, identityFile
        var id: Self { self }
    }

    public init(model: ConnectionSheetModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.title).font(Tokens.interface(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            urlField
            fields
            labelRow
            Toggle(isOn: $model.readOnly) { Text("Read-only").font(Tokens.interface(13)) }
                .toggleStyle(.switch).tint(Tokens.accent)
                .accessibilityHint("Blocks every write, script and admin command on this connection")
            sections
            footer
        }
        .foregroundStyle(Tokens.fg)
        .padding(.vertical, 28).padding(.horizontal, 32)
        .frame(width: 560)
        .background(Tokens.sheet)
        // ⌘V outside a text field fills the form from a copied URL (FR-CN08).
        .focusable().focusEffectDisabled()
        .onPasteCommand(of: [.plainText]) { _ in
            if let text = NSPasteboard.general.string(forType: .string) { model.paste(text) }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }), allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            switch picking {
            case .caFile: model.tlsCAFile = url.path
            case .identityFile: model.tunnelIdentityFile = url.path
            case nil: break
            }
            picking = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    // MARK: Fields

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SheetTextField(label: "Connection URL", placeholder: "Paste a URL to fill the form", text: $model.urlText, mono: true, showsLabel: false)
                .onChange(of: model.urlText) { model.urlTextChanged() }
                .onSubmit { model.applyURL(model.urlText) }
            if let message = model.urlMessage { Text(message).font(Tokens.interface(12)).foregroundStyle(Tokens.muted) }
        }
    }

    private var fields: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow { SheetTextField(label: "Name", placeholder: model.host, text: $model.name).gridCellColumns(4) }
            GridRow {
                SheetTextField(label: "Host", text: $model.host, mono: true).gridCellColumns(3)
                SheetTextField(label: "Port", text: $model.port, mono: true)
            }
            GridRow {
                SheetTextField(label: "Username", placeholder: "default", text: $model.username).gridCellColumns(2)
                passwordField.gridCellColumns(2)
            }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password · saved in Keychain").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            SecureField("", text: $model.password, prompt: Text(model.hasSavedPassword && !model.removeSavedPassword ? "Saved — type to replace" : "").foregroundStyle(Tokens.muted.opacity(0.7)))
                .modifier(FieldStyle(mono: false))
                .accessibilityLabel("Password, saved in Keychain")
            if model.hasSavedPassword {
                Toggle("Remove saved password", isOn: $model.removeSavedPassword).font(Tokens.interface(12)).toggleStyle(.checkbox)
            }
            if model.savedPasswordWillBeRemoved {
                Text("The connection changed, so the saved password will be removed.").font(Tokens.interface(12)).foregroundStyle(Tokens.warning)
            }
        }
    }

    private var labelRow: some View {
        HStack(spacing: 12) {
            Text("Label").font(Tokens.interface(12)).foregroundStyle(Tokens.muted).frame(width: 60, alignment: .leading).accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(model.labels, id: \.color) { label in
                    LabelDot(label: label, selected: model.label == label.color) { model.label = label.color }
                }
            }
            Text(model.labels.first { $0.color == model.label }?.name ?? "").font(Tokens.interface(12.5)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Label")
    }

    // MARK: Collapsed rows

    private var sections: some View {
        VStack(spacing: 0) {
            ForEach(ConnectionSheetModel.Section.allCases, id: \.self) { section in
                SectionRow(section: section, value: summary(section), problem: problem(in: section), expanded: model.expanded.contains(section)) {
                    if model.expanded.contains(section) { model.expanded.remove(section) } else { model.expanded.insert(section) }
                }
                if model.expanded.contains(section) {
                    content(section).padding(.vertical, 12)
                    Rectangle().fill(Tokens.hair).frame(height: 1)
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Tokens.hair).frame(height: 1) }
    }

    private func summary(_ section: ConnectionSheetModel.Section) -> String {
        switch section {
        case .tls:
            guard model.tlsEnabled else { return "Off" }
            return model.tlsSkipVerification ? "On · not verified" : "On"
        case .tunnel:
            switch model.tunnelKind {
            case .none: return "None"
            case .savedHost: return model.sshHosts.first { $0.id == model.tunnelHostID }?.name ?? "Choose a host"
            case .inline: return model.tunnelDestination.isEmpty ? "Custom" : model.tunnelDestination
            }
        case .advanced: return model.database == "0" ? "" : "db\(model.database)"
        }
    }

    private func problem(in section: ConnectionSheetModel.Section) -> String? {
        guard let field = model.invalidField, ConnectionSheetModel.section(of: field) == section else { return nil }
        return ConnectionSheetModel.message(for: field)
    }

    @ViewBuilder private func content(_ section: ConnectionSheetModel.Section) -> some View {
        switch section {
        case .tls: tlsContent
        case .tunnel: tunnelContent
        case .advanced: advancedContent
        }
    }

    private var tlsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Use TLS", isOn: $model.tlsEnabled).toggleStyle(.switch).tint(Tokens.accent)
            if model.tlsEnabled {
                SheetTextField(label: "Server name (SNI)", placeholder: model.host, text: $model.tlsServerName, mono: true)
                HStack(alignment: .bottom, spacing: 8) {
                    SheetTextField(label: "Custom CA (PEM)", placeholder: "System trust", text: $model.tlsCAFile, mono: true)
                    Button("Choose…") { picking = .caFile }.accessibilityLabel("Choose a custom CA file")
                }
                Toggle("Skip verification", isOn: $model.tlsSkipVerification).toggleStyle(.checkbox)
                    .accessibilityHint("Connects without checking the certificate; the connection shows TLS not verified")
            }
        }
        .font(Tokens.interface(13))
    }

    private var tunnelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tunnel", selection: $model.tunnelKind) {
                ForEach(ConnectionSheetModel.TunnelKind.allCases, id: \.self) { kind in
                    // A saved host needs the SSH hosts library; without one the option is hidden (unless already chosen).
                    if kind != .savedHost || model.hosts != nil || model.tunnelKind == .savedHost { Text(kind.rawValue).tag(kind) }
                }
            }
            .pickerStyle(.segmented)
            switch model.tunnelKind {
            case .none: EmptyView()
            case .savedHost:
                if let hosts = model.hosts { HostPickerSection(sheet: model, hosts: hosts) } else { Text("SSH hosts aren't available.").foregroundStyle(Tokens.muted) }
            case .inline:
                Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        SheetTextField(label: "SSH destination", placeholder: "bastion or user@host", text: $model.tunnelDestination, mono: true).gridCellColumns(3)
                        SheetTextField(label: "SSH port", placeholder: "22", text: $model.tunnelPort, mono: true)
                    }
                    GridRow {
                        SheetTextField(label: "SSH user", placeholder: "from ~/.ssh/config", text: $model.tunnelUser).gridCellColumns(2)
                        HStack(alignment: .bottom, spacing: 8) {
                            SheetTextField(label: "Identity file", placeholder: "default", text: $model.tunnelIdentityFile, mono: true)
                            Button("Choose…") { picking = .identityFile }.accessibilityLabel("Choose an SSH identity file")
                        }
                        .gridCellColumns(2)
                    }
                }
            }
            if model.tunnelKind != .none {
                Text("Host and Port are resolved from the SSH server's side.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            }
        }
        .font(Tokens.interface(13))
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    SheetTextField(label: "Database", text: $model.database, mono: true)
                    SheetTextField(label: "Connect timeout (ms)", placeholder: "10000", text: $model.connectTimeout, mono: true)
                    SheetTextField(label: "Command timeout (ms)", placeholder: "30000", text: $model.commandTimeout, mono: true)
                }
                GridRow {
                    SheetTextField(label: "Key separator", placeholder: ":", text: $model.separator, mono: true)
                    SheetTextField(label: "Client name", placeholder: "keel", text: $model.clientName, mono: true).gridCellColumns(2)
                }
            }
            Toggle("Reconnect on launch", isOn: $model.reconnectOnLaunch).toggleStyle(.checkbox)
        }
        .font(Tokens.interface(13))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.saveError {
                Text(error).font(Tokens.interface(12.5)).foregroundStyle(Tokens.danger).accessibilityLabel("Couldn't save: \(error)")
            }
            HStack(spacing: 10) {
                Button("Test") { model.test() }
                    .buttonStyle(.plain).foregroundStyle(Tokens.accent).font(Tokens.interface(13)).fixedSize().padding(.horizontal, 4).frame(height: 34)
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.visibleTestStatus == .testing)
                    .accessibilityHint("Connects with these settings without saving them")
                testLine.layoutPriority(1)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(SheetButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.save() } }
                    .buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
            }
        }
    }

    @ViewBuilder private var testLine: some View {
        switch model.visibleTestStatus {
        case .idle: EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
            }
        case .succeeded(let line):
            Text(line).font(Tokens.interface(12.5)).foregroundStyle(Tokens.success).lineLimit(1).truncationMode(.tail).help(line)
        case .failed(let failure):
            // One line (FR-CN19): the category's message; its fix in the tooltip and for VoiceOver.
            Text("✕ \(failure.message)").font(Tokens.interface(12.5)).foregroundStyle(Tokens.danger).lineLimit(1).truncationMode(.tail)
                .help("\(failure.message)\n\(failure.suggestion)")
                .accessibilityLabel("Test failed: \(failure.message)").accessibilityHint(failure.suggestion)
        case .invalid(let message):
            Text("✕ \(message)").font(Tokens.interface(12.5)).foregroundStyle(Tokens.danger).lineLimit(1).truncationMode(.tail).help(message)
        }
    }
}

// MARK: - Components

/// A labeled field on `field` (36 high, radius 8). The visible label is the accessibility label.
struct SheetTextField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var mono = false
    var showsLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel { Text(label).font(Tokens.interface(12)).foregroundStyle(Tokens.muted).accessibilityHidden(true) }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Tokens.muted.opacity(0.7)))
                .modifier(FieldStyle(mono: mono))
                .accessibilityLabel(label)
        }
    }
}

struct FieldStyle: ViewModifier {
    let mono: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Tokens.mono() : Tokens.interface(13))
            .autocorrectionDisabled()
            .padding(.horizontal, 12).frame(height: 36)
            .background(Tokens.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A 22 pt label button: a 14 pt dot, ringed in the accent when selected. VoiceOver reads the label's name.
private struct LabelDot: View {
    let label: ProfileLabel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(selected ? Tokens.accent : .clear, lineWidth: 2)
                if let color = Tokens.label(label.color) {
                    Circle().fill(color).frame(width: 14, height: 14)
                } else {
                    Circle().strokeBorder(Tokens.muted, lineWidth: 1).frame(width: 14, height: 14)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label.name)
        .accessibilityLabel(label.color == .none ? "No label" : label.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A collapsed settings row: name, current value in `muted`, chevron. 44 high with a hairline below.
private struct SectionRow: View {
    let section: ConnectionSheetModel.Section
    let value: String
    let problem: String?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Text(section.rawValue).font(Tokens.interface(13))
                Spacer()
                if let problem {
                    Text(problem).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).lineLimit(1)
                } else {
                    Text(value).font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.muted)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if !expanded { Rectangle().fill(Tokens.hair).frame(height: 1) } }
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(expanded ? "Hides these settings" : "Shows these settings")
    }

    /// A problem replaces the value; otherwise the value (if any) then the expanded state.
    private var accessibilityValue: String {
        if let problem { return problem }
        let state = expanded ? "expanded" : "collapsed"
        return value.isEmpty ? state : "\(value), \(state)"
    }
}

/// Footer buttons: Save on `accent` (600), Cancel on `field`; 34 high, radius 8.
struct SheetButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize()
            .font(Tokens.interface(13, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Tokens.onAccent : Tokens.fg)
            .padding(.horizontal, primary ? 20 : 16).frame(height: 34)
            .background(primary ? Tokens.accent : Tokens.field, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

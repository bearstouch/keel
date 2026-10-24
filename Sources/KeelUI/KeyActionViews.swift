import AppKit
import KeelCore
import SwiftUI

/// Rename…: the new name as text; a name that isn't valid UTF-8 starts empty rather than escaped, so the escape text is
/// never mistaken for the bytes (FR-KB10). Renaming onto an existing key asks before anything is replaced (FR-ED10).
struct RenameKeySheet: View {
    @ObservedObject var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var overwrite: KeyActions.RenameOverwrite?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Key").font(Tokens.interface(15, weight: .semibold))
            Text(KeyDisplay.name(session.key)).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
            TextField("New name", text: $name).font(Tokens.mono(12.5)).accessibilityLabel("New key name")
                .onChange(of: name) { failure = nil }
            if let failure { Text(failure).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Renaming…" : "Rename") { Task { await rename(nil) } }
                    .keyboardShortcut(.defaultAction).disabled(name.isEmpty || busy || Data(name.utf8) == session.key)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
        .onAppear {
            let text = String(decoding: session.key, as: UTF8.self)
            if Data(text.utf8) == session.key { name = text }
        }
        .alert(
            "Replace the key “\(name)”?", isPresented: Binding(get: { overwrite != nil }, set: { if !$0 { overwrite = nil } })
        ) {
            Button("Replace", role: .destructive) { Task { await rename(overwrite) } }
            Button("Cancel", role: .cancel) { overwrite = nil }
        } message: {
            Text("A key with this name already exists. Nothing has changed yet; Replace deletes it and renames this key.")
        }
    }

    private func rename(_ confirmed: KeyActions.RenameOverwrite?) async {
        busy = true; failure = nil
        defer { busy = false }
        switch await session.rename(to: Data(name.utf8), overwrite: confirmed) {
        case .renamed: dismiss()
        case .needsOverwrite(let token): overwrite = token
        case .failed(let message): overwrite = nil; failure = message
        }
    }
}

/// Set TTL…: the current expiry as a clock time ("—" without one), presets, a custom duration, a date and time, and
/// Persist (FR-ED11). Each choice applies at once and the expiry line shows the result.
struct SetTTLSheet: View {
    @ObservedObject var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var unit = DurationUnit.minutes
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var busy = false
    @State private var failure: String?

    enum DurationUnit: String, CaseIterable, Identifiable {
        case seconds, minutes, hours, days
        var id: String { rawValue }
        var milliseconds: Int64 {
            switch self {
            case .seconds: return 1_000
            case .minutes: return 60_000
            case .hours: return 3_600_000
            case .days: return 86_400_000
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set TTL").font(Tokens.interface(15, weight: .semibold))
            HStack(spacing: 6) {
                Text("Expires").foregroundStyle(Tokens.muted)
                Text(session.expiry.map { $0.text() } ?? "…").font(Tokens.mono(12)).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                ForEach(KeyActions.TTLPreset.allCases) { preset in
                    Button(preset.rawValue) { apply(.preset(preset)) }.accessibilityLabel("Expire in \(preset.rawValue)")
                }
            }
            HStack(spacing: 8) {
                TextField("Duration", text: $amount).frame(width: 90).accessibilityLabel("Custom duration")
                Picker("Unit", selection: $unit) { ForEach(DurationUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                Button("Set") { apply(.after(milliseconds: customMilliseconds ?? 0)) }.disabled(customMilliseconds == nil)
            }
            HStack(spacing: 8) {
                DatePicker("At", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute]).accessibilityLabel("Expiry date and time")
                Button("Set") { apply(.at(date)) }
            }
            if let failure { Text(failure).font(Tokens.interface(12)).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Persist") { apply(.persist) }.help("Remove the expiry (PERSIST)")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(Tokens.interface(12.5)).textFieldStyle(.roundedBorder).padding(20).frame(width: 440)
        .disabled(busy)
        .task { await session.loadExpiry() }
    }

    /// A whole positive number of the unit; nil for anything else (the server would delete the key for 0 or less).
    private var customMilliseconds: Int64? {
        guard let value = Int64(amount.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        let (product, overflow) = value.multipliedReportingOverflow(by: unit.milliseconds)
        return overflow ? nil : product
    }

    private func apply(_ change: KeyActions.TTLChange) {
        busy = true; failure = nil
        Task {
            failure = await session.setTTL(change)
            busy = false
        }
    }
}

/// The open key's ⋯ menu actions that need no sheet: Copy Value and Export Value… (FR-ED15).
@MainActor
enum KeyValueTransfer {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The save panel, then the bytes written as they are; returns why it failed, nil when written or cancelled.
    static func export(_ session: EditorSession) -> String? {
        guard let data = session.exportData() else { return session.exportBlock }
        let panel = NSSavePanel()
        panel.title = "Export Value"; panel.prompt = "Export"; panel.nameFieldStringValue = session.exportFileName; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { try ValueExport.write(data, to: url) } catch { return "The value couldn't be written: \(error.localizedDescription)" }
        return nil
    }
}

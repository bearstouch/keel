import AppKit
import KeelCore
import SwiftUI
import UniformTypeIdentifiers

/// File → Import / Export Connections (FR-CN14). Export writes the store's profiles and folders without secrets;
/// import reads a file, shows its counts and conflicts, and changes nothing until the person picks a policy and
/// clicks Import. Every outcome that isn't a plain success ends in `message`.
@MainActor
public final class ProfileTransferModel: ObservableObject {
    /// A read and validated file waiting for the preview sheet's answer.
    public struct PendingImport: Identifiable, Equatable {
        public let id = UUID()
        public let export: ProfileExport
        public let preview: ProfileImportPreview
    }

    public typealias ChooseFile = @MainActor () -> URL?

    @Published public private(set) var pending: PendingImport?
    /// Skip is preselected: it is the only policy that can't change a saved profile.
    @Published public var policy: ProfileImportPolicy = .skip
    @Published public private(set) var isImporting = false
    /// Why the last Import click failed, shown inside the open sheet (an alert behind it wouldn't be seen).
    @Published public private(set) var failure: String?
    /// One line for the alert; nil when there is nothing to say.
    @Published public var message: String?

    private let store: ProfileStore
    private let chooseImport: ChooseFile
    private let chooseExport: ChooseFile
    private let read: @Sendable (URL) throws -> Data
    private let write: @Sendable (Data, URL) throws -> Void
    /// Set from the file panel until the preview opens, so a second menu click can't race the first file.
    private var reading = false

    public init(
        store: ProfileStore, chooseImport: @escaping ChooseFile = ProfileTransferModel.openPanel, chooseExport: @escaping ChooseFile = ProfileTransferModel.savePanel,
        read: @escaping @Sendable (URL) throws -> Data = ProfileTransferModel.readCapped, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.store = store; self.chooseImport = chooseImport; self.chooseExport = chooseExport; self.read = read; self.write = write
    }

    // MARK: Export

    public func exportConnections() async {
        // While recovering, the store shows an empty or backup document; exporting it could replace a good export.
        guard await store.isWritable else { message = "Connections can't be exported while they are being recovered."; return }
        let data: Data
        do { data = try await store.export().encoded() } catch {
            message = error.message; return
        }
        guard let url = chooseExport() else { return }
        let write = write
        // Off the main actor: the destination may be a slow or network volume.
        do { try await Task.detached { try write(data, url) }.value } catch { message = "Couldn't write the export file; nothing was saved." }
    }

    // MARK: Import

    public func beginImport() async {
        guard pending == nil, !reading else { return }
        reading = true
        defer { reading = false }
        guard let url = chooseImport() else { return }
        let read = read
        let export: ProfileExport
        do {
            export = try await Task.detached { () throws -> ProfileExport in try ProfileExport.decode(read(url)) }.value
        } catch let error as ProfileImportError {
            message = error.message; return
        } catch {
            message = "Couldn't read the file; nothing was imported."; return
        }
        guard !export.profiles.isEmpty || !export.folders.isEmpty else { message = "This export has no connections."; return }
        policy = .skip; failure = nil
        pending = PendingImport(export: export, preview: await store.previewImport(export))
    }

    public func cancelImport() { guard !isImporting else { return }; pending = nil }

    /// Applies the file with the chosen policy. On failure the preview stays open with `failure`, so the person can
    /// retry or cancel; the store guarantees nothing changed.
    public func confirmImport() async {
        guard let pending, !isImporting else { return }
        isImporting = true; failure = nil
        defer { isImporting = false }
        do throws(ProfileStoreError) {
            let result = try await store.importProfiles(pending.export, policy: policy)
            self.pending = nil
            message = Self.summary(result)
        } catch {
            failure = error.sheetMessage
        }
    }

    // MARK: Words

    /// The preview's first line: "3 connections and 1 folder."
    public static func contents(_ preview: ProfileImportPreview) -> String {
        let profiles = count(preview.profileCount, "connection")
        return (preview.folderCount == 0 ? profiles : "\(profiles) and \(count(preview.folderCount, "folder"))") + "."
    }

    /// The conflict line, naming at most three saved records.
    public static func conflicts(_ preview: ProfileImportPreview) -> String? {
        let names = preview.conflictingProfiles + preview.conflictingFolders
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return "\(names.count) already \(names.count == 1 ? "exists" : "exist"): \(shown)\(names.count > 3 ? " and \(names.count - 3) more" : "")."
    }

    static func summary(_ result: ProfileImportResult) -> String {
        var parts: [String] = []
        if result.added > 0 { parts.append("added \(count(result.added, "connection"))") }
        if result.replaced > 0 { parts.append("replaced \(result.replaced)") }
        if result.foldersAdded > 0 { parts.append("added \(count(result.foldersAdded, "folder"))") }
        if result.foldersRenamed > 0 { parts.append("renamed \(count(result.foldersRenamed, "folder"))") }
        guard !parts.isEmpty else { return "Nothing changed: everything in the file is already saved." }
        let text = parts.joined(separator: ", ")
        // Only folders changed: no connection needs a password.
        guard result.added + result.replaced > 0 else { return text.prefix(1).uppercased() + text.dropFirst() + "." }
        // Exports never carry secrets, so new and re-pointed profiles need their password entered again.
        return text.prefix(1).uppercased() + text.dropFirst() + ". Passwords aren't part of an export; enter them in each connection."
    }

    static func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }

    public static func title(_ policy: ProfileImportPolicy) -> String {
        switch policy {
        case .skip: "Skip existing"
        case .replace: "Replace existing"
        case .keepBoth: "Keep both"
        }
    }

    // MARK: Files

    public static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Connections"; panel.prompt = "Choose"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func savePanel() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Connections"; panel.prompt = "Export"
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Keel Connections.json"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Reads at most one byte past the limit, so a huge file is refused as too large without being loaded whole.
    public nonisolated static func readCapped(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: ProfileExport.byteLimit + 1) ?? Data()
    }
}

/// The import preview: what the file holds, what collides, the policy, and Cancel / Import. Escape cancels.
struct ProfileImportSheet: View {
    @ObservedObject var model: ProfileTransferModel
    let pending: ProfileTransferModel.PendingImport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Connections").font(Tokens.interface(15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(ProfileTransferModel.contents(pending.preview))
            if let conflicts = ProfileTransferModel.conflicts(pending.preview) {
                Text(conflicts).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                Picker("Existing connections", selection: $model.policy) {
                    ForEach(ProfileImportPolicy.allCases, id: \.self) { Text(ProfileTransferModel.title($0)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("What to do with connections that already exist")
            }
            Text("Passwords and client certificates aren't part of an export.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            if let failure = model.failure {
                Text(failure).foregroundStyle(Tokens.danger).fixedSize(horizontal: false, vertical: true).accessibilityLabel("Import failed: \(failure)")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.confirmImport() } }.keyboardShortcut(.defaultAction).disabled(model.isImporting)
            }
        }
        .font(Tokens.interface(13))
        .foregroundStyle(Tokens.fg)
        .padding(20)
        .frame(width: 400)
        .background(Tokens.sheet)
    }
}

extension View {
    /// The import preview sheet and the transfer alert over this view.
    public func profileTransfer(_ model: ProfileTransferModel?) -> some View { modifier(ProfileTransferModifier(model: model)) }
}

private struct ProfileTransferModifier: ViewModifier {
    let model: ProfileTransferModel?

    func body(content: Content) -> some View {
        if let model { content.modifier(Presenting(model: model)) } else { content }
    }

    private struct Presenting: ViewModifier {
        @ObservedObject var model: ProfileTransferModel

        func body(content: Content) -> some View {
            content
                // Dismissal goes through Cancel / Import, so an import in flight can't lose its sheet.
                .sheet(item: Binding(get: { model.pending }, set: { _ in })) { pending in
                    ProfileImportSheet(model: model, pending: pending).interactiveDismissDisabled()
                }
                .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("OK", role: .cancel) {}
                }
        }
    }
}

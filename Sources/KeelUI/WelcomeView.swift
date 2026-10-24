import AppKit
import Combine
import Foundation
import KeelCore
import SwiftUI

/// The welcome screen of a window without tabs (FR-AP08): recent connections, New Connection, Paste URL and Import.
/// Recents are the app's (`AppModel.recentProfileIDs`, saved in `windows.json`), shown with the sidebar's current names
/// and labels; a deleted profile drops out.
@MainActor
public final class WelcomeModel: ObservableObject {
    public struct Recent: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var name: String
        public var label: LabelColor
        /// nil for no label.
        public var labelName: String?
        /// `host:port`, plus the tunnel (as the sidebar's tooltip); never the username or password.
        public var address: String

        /// "payments-prod, Production, 10.0.0.5:6379": name, label and address, in words.
        public var accessibilityLabel: String { [name, labelName ?? "no label", address].joined(separator: ", ") }
    }

    /// Rows the screen shows; more recents stay saved for when one of these is deleted.
    public static let recentLimit = 5

    public let sidebar: SidebarModel
    private let connections: ConnectionSheetPresenter?
    private let transfer: ProfileTransferModel?
    private let readClipboard: @MainActor () -> String?
    private var changes: AnyCancellable?

    public init(
        sidebar: SidebarModel, connections: ConnectionSheetPresenter? = nil, transfer: ProfileTransferModel? = nil,
        readClipboard: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) }
    ) {
        self.sidebar = sidebar; self.connections = connections; self.transfer = transfer; self.readClipboard = readClipboard
        // Profiles come from the sidebar (renames, deletes, labels), recents from the app.
        var sources = [sidebar.objectWillChange.eraseToAnyPublisher()]
        if let app = sidebar.tabs.app { sources.append(app.objectWillChange.eraseToAnyPublisher()) }
        changes = Publishers.MergeMany(sources).sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public var recents: [Recent] { Self.recents(sidebar.tabs.app?.recentProfileIDs ?? [], in: sidebar.document) }

    /// Saved profiles exist: the empty-recents hint then points at the sidebar instead of New Connection.
    public var hasProfiles: Bool { !sidebar.document.profiles.isEmpty }

    /// `ids` in order, skipping profiles no longer saved, at most `recentLimit`.
    static func recents(_ ids: [UUID], in document: ConnectionsDocument) -> [Recent] {
        let profiles = Dictionary(document.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.lazy.compactMap { profiles[$0] }.prefix(recentLimit).map { profile in
            let settings = profile.settings
            return Recent(
                id: profile.id, name: settings.name, label: settings.label, labelName: settings.label == .none ? nil : document.label(settings.label).name,
                address: SidebarModel.tooltip(settings))
        }
    }

    // MARK: Actions

    /// Opens (or focuses) the profile's tab, as a double-click in the sidebar does.
    public func open(_ profileID: UUID) { sidebar.open(profileID) }

    public func newConnection() { connections?.newConnection() }

    /// New Connection filled from a `redis://` / `rediss://` URL on the clipboard (FR-CN08).
    public func pasteURL() { connections?.newConnection(pastingURL: readClipboard()) }

    public func importConnections() { Task { await transfer?.beginImport() } }
}

/// The welcome screen (FR-AP08, drawn after 08 Design's components): the mark, the three actions, then the recents.
struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    static let accessibilityLabel = "Welcome to Keel"

    var body: some View {
        VStack(spacing: 0) {
            KeelMark().frame(width: 56, height: 56).padding(.bottom, 14)
            Text("Keel").font(Tokens.interface(28, weight: .semibold)).tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            Text("Redis, Valkey and Dragonfly").foregroundStyle(Tokens.muted).padding(.top, 4)
            HStack(spacing: 8) {
                Button("New Connection…") { model.newConnection() }.buttonStyle(.borderedProminent).tint(Tokens.accent)
                Button("Paste URL") { model.pasteURL() }.help("New connection from a redis:// or rediss:// URL on the clipboard")
                Button("Import…") { model.importConnections() }.help("Import connections from a Keel export")
            }
            .controlSize(.large)
            .padding(.top, 22)
            recents.padding(.top, 30)
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Tokens.fg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel)
    }

    @ViewBuilder private var recents: some View {
        let rows = model.recents
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(Tokens.interface(12, weight: .semibold)).foregroundStyle(Tokens.muted)
                .padding(.horizontal, 10).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text(model.hasProfiles ? "Connections you open appear here. Double-click one in the sidebar to open it." : "Connections you open appear here.")
                    .font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
                    .padding(.horizontal, 10)
            }
            ForEach(rows) { row in RecentRow(row: row) { model.open(row.id) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One recent connection: the label dot, the name and the address; the whole row opens it.
private struct RecentRow: View {
    let row: WelcomeModel.Recent
    let open: () -> Void
    @State private var hovering = false
    /// Plain buttons draw no focus of their own: the accent ring shows keyboard focus (DS-02).
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                labelDot
                Text(row.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 12)
                Text(row.address).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovering ? Tokens.soft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(focused)
        .onHover { hovering = $0 }
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Opens the connection in a tab")
    }

    /// The label's dot, as in the sidebar; no label is an empty `muted` ring.
    @ViewBuilder private var labelDot: some View {
        if let color = Tokens.label(row.label) {
            Circle().fill(color).frame(width: 8, height: 8)
        } else {
            Circle().strokeBorder(Tokens.muted, lineWidth: 1).frame(width: 8, height: 8)
        }
    }
}

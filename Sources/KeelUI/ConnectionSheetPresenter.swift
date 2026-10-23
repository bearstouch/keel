import Combine
import Foundation
import KeelCore
import KeelSSH
import SwiftUI

/// Opens the New / Edit Connection sheet over the window and closes it when the model reports Save or Cancel.
@MainActor
public final class ConnectionSheetPresenter: ObservableObject {
    @Published public private(set) var model: ConnectionSheetModel?
    private let store: ProfileStore
    private let tester: any ConnectionTesting
    private let sshHosts: @MainActor () async -> [SavedHost]
    private var finished: AnyCancellable?
    /// Set while a sheet is being prepared, so a second ⌘N during the awaits can't build (and orphan) another one.
    private var presenting = false

    public init(store: ProfileStore, tester: any ConnectionTesting, sshHosts: @escaping @MainActor () async -> [SavedHost] = { [] }) {
        self.store = store; self.tester = tester; self.sshHosts = sshHosts
    }

    public func newConnection(folderID: UUID? = nil) { Task { await present(.create(folderID: folderID)) } }

    /// Edit Connection is the same sheet, filled from the saved profile.
    public func edit(_ profileID: UUID) {
        Task {
            guard let profile = await store.profile(profileID) else { return }
            await present(.edit(profile))
        }
    }

    func present(_ mode: ConnectionSheetModel.Mode) async {
        guard model == nil, !presenting else { return }
        presenting = true
        defer { presenting = false }
        let labels = await store.labels
        let hosts = await sshHosts()
        let sheet = ConnectionSheetModel(mode: mode, labels: labels, sshHosts: hosts, tester: tester, store: store)
        finished = sheet.$outcome.compactMap { $0 }.sink { [weak self] _ in
            self?.model = nil; self?.finished = nil
        }
        model = sheet
    }
}

extension ConnectionSheetModel: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension View {
    /// Shows `presenter`'s connection sheet over this view. The sheet closes only through Cancel or Save, so Cancel
    /// always runs and wipes the typed password.
    public func connectionSheet(_ presenter: ConnectionSheetPresenter?) -> some View { modifier(ConnectionSheetModifier(presenter: presenter)) }
}

private struct ConnectionSheetModifier: ViewModifier {
    let presenter: ConnectionSheetPresenter?

    func body(content: Content) -> some View {
        if let presenter { content.modifier(Presenting(presenter: presenter)) } else { content }
    }

    private struct Presenting: ViewModifier {
        @ObservedObject var presenter: ConnectionSheetPresenter

        func body(content: Content) -> some View {
            // The setter is a no-op: dismissal goes through the model's Cancel / Save, which clears `model`.
            content.sheet(item: Binding(get: { presenter.model }, set: { _ in })) { model in
                ConnectionSheet(model: model).interactiveDismissDisabled()
            }
        }
    }
}

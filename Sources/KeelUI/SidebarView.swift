import KeelCore
import SwiftUI

/// The connections sidebar (FR-CN13, board `Sidebar`): "Connections" heading with `+`, folder groups under small muted
/// headings, one-line rows, and the Keel mark at the bottom left. Double-click or Return opens (⌥ forces a new tab);
/// the arrow keys move the selection; drag a row onto a row or a heading to reorder or refile it.
public struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @FocusState private var focused: Bool
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var deleting: SidebarModel.Row?

    public static let width: CGFloat = 232

    /// The name prompts: a folder name or a profile's new name.
    private enum Prompt: Equatable {
        case newFolder, renameFolder(UUID), renameProfile(UUID)

        var title: String {
            switch self {
            case .newFolder: "New Folder"
            case .renameFolder: "Rename Folder"
            case .renameProfile: "Rename Connection"
            }
        }
    }

    public init(model: SidebarModel) { self.model = model }

    public var body: some View { dialogs(content).task { model.start() } }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.groups) { group($0) }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            // Focused with nothing selected: ↓ selects the first row; until then the list shows the focus.
            .focusRing(focused && model.selectedProfileID == nil, cornerRadius: 0)
            .contextMenu {
                Button("New Connection…") { model.newConnection() }; Button("New Folder…") { ask(.newFolder) }
            }
            mark
        }
        .font(Tokens.interface(13))
        .foregroundStyle(Tokens.fg)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Tokens.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.sidebarHair).frame(width: 1).ignoresSafeArea() }
        .focusable().focused($focused).focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onKeyPress(keys: [.return]) { press in
            model.openSelection(newTab: press.modifiers.contains(.option)); return .handled
        }
        .onKeyPress(keys: ["i"]) { press in
            guard press.modifiers.subtracting(.capsLock) == .command else { return .ignored }
            model.editSelection(); return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connections")
    }

    /// The name prompt, the delete confirmation and refused changes.
    private func dialogs(_ content: some View) -> some View {
        content
            .alert(prompt?.title ?? "", isPresented: isPresented($prompt)) {
                TextField("Name", text: $promptText)
                Button("Cancel", role: .cancel) { prompt = nil }
                Button(prompt == .newFolder ? "Create" : "Rename") { submit() }
            }
            .alert(
                "Delete “\(deleting?.name ?? "")”?", isPresented: isPresented($deleting), presenting: deleting
            ) { row in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await model.delete(row.id) } }
            } message: { _ in
                Text("Its saved password is removed from the Keychain.")
            }
            .alert(model.message ?? "", isPresented: isPresented($model.message)) {
                Button("OK", role: .cancel) {}
            }
    }

    /// Shown while `value` is set; dismissing clears it.
    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: Parts

    /// Leaves room for the traffic lights (the window's content runs under its title bar), then "Connections" and `+`.
    private var heading: some View {
        HStack {
            Text("Connections").font(Tokens.interface(12, weight: .semibold)).foregroundStyle(Tokens.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                model.newConnection()
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.muted)
            .help("New Connection").accessibilityLabel("New connection")
        }
        .padding(.top, 58).padding(.leading, 20).padding(.trailing, 12).padding(.bottom, 10)
        // Dropping on the heading files a profile at the top level.
        .dropDestination(for: String.self) { items, _ in drop(items, into: nil) }
    }

    @ViewBuilder private func group(_ group: SidebarModel.Group) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let folderID = group.folderID { folderHeading(group, folderID: folderID) }
            if !group.collapsed {
                ForEach(group.rows) { row($0, folderID: group.folderID) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.name ?? "Connections")
    }

    private func folderHeading(_ group: SidebarModel.Group, folderID: UUID) -> some View {
        Button {
            Task { await model.toggleCollapsed(folderID) }
        } label: {
            HStack(spacing: 4) {
                Text(group.name ?? "").lineLimit(1).truncationMode(.tail)
                // Shown only while collapsed: "show less, reveal on demand", but a hidden group must still look hidden.
                if group.collapsed { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
                Spacer(minLength: 0)
            }
            .font(Tokens.interface(11)).foregroundStyle(Tokens.muted)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name ?? "") folder")
        .accessibilityValue(group.collapsed ? "collapsed" : "expanded")
        .accessibilityHint(group.collapsed ? "Shows its connections" : "Hides its connections")
        .draggable(SidebarModel.DragItem.folder(folderID).payload)
        .dropDestination(for: String.self) { items, _ in drop(items, into: folderID) }
        .contextMenu {
            Button("New Connection…") { model.newConnection(inFolder: folderID) }
            Button(group.collapsed ? "Expand" : "Collapse") { Task { await model.toggleCollapsed(folderID) } }
            Divider()
            Button("Rename…") { ask(.renameFolder(folderID), text: group.name ?? "") }
            Button("New Folder…") { ask(.newFolder) }
            Divider()
            Button("Delete Folder") { Task { await model.deleteFolder(folderID) } }
        }
    }

    private func row(_ row: SidebarModel.Row, folderID: UUID?) -> some View {
        let selected = model.selectedProfileID == row.id
        return HStack(spacing: 10) {
            labelDot(row.label)
            Text(row.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            switch row.status {
            case .connected: Image(systemName: "link").font(.system(size: 10, weight: .medium)).foregroundStyle(Tokens.muted)
            case .failed: Text("Failed").font(Tokens.interface(11)).foregroundStyle(Tokens.danger)
            case .connecting, .disconnected: EmptyView()
            }
        }
        .font(Tokens.interface(13, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 10).frame(height: 32)
        .background(selected ? Tokens.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
        // The sidebar takes focus as a whole; its selected row shows it (NFR-AX02).
        .focusRing(focused && selected)
        .contentShape(Rectangle())
        .help(row.tooltip)
        .onTapGesture(count: 2) { model.open(row.id, newTab: NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(
            TapGesture().onEnded {
                model.selectedProfileID = row.id; focused = true
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.tooltip)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.open(row.id) }
        .accessibilityAction(named: "Open in New Tab") { model.open(row.id, newTab: true) }
        .accessibilityAction(named: "Edit…") { model.edit(row.id) }
        .draggable(SidebarModel.DragItem.profile(row.id).payload)
        .dropDestination(for: String.self) { items, _ in drop(items, into: folderID, before: row.id) }
        .contextMenu { menu(for: row, folderID: folderID) }
    }

    @ViewBuilder private func menu(for row: SidebarModel.Row, folderID: UUID?) -> some View {
        Button("Connect") { model.open(row.id) }
        Button("Connect in New Tab") { model.open(row.id, newTab: true) }
        Divider()
        Button("Edit…") { model.edit(row.id) }
        Button("Rename…") { ask(.renameProfile(row.id), text: row.name) }
        Button("Duplicate") { Task { await model.duplicate(row.id) } }
        Button("Copy URL") { model.copyURL(row.id) }
        // The keyboard and VoiceOver way to refile a profile, besides dragging.
        Menu("Move To") {
            Button("No Folder") { Task { await model.move(row.id, toFolder: nil) } }.disabled(folderID == nil)
            ForEach(model.document.folders) { folder in
                Button(folder.name) { Task { await model.move(row.id, toFolder: folder.id) } }.disabled(folder.id == folderID)
            }
        }
        Divider()
        Button("Delete…") { deleting = row }
    }

    /// The label's dot; no label is an empty `muted` ring, as in the sheet.
    @ViewBuilder private func labelDot(_ label: LabelColor) -> some View {
        if let color = Tokens.label(label) {
            Circle().fill(color).frame(width: 8, height: 8)
        } else {
            Circle().strokeBorder(Tokens.muted, lineWidth: 1).frame(width: 8, height: 8)
        }
    }

    private var mark: some View {
        HStack(spacing: 9) {
            KeelMark().frame(width: 24, height: 24)
            Text("Keel").font(Tokens.interface(13.5, weight: .semibold)).tracking(-0.13)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keel")
    }

    // MARK: Actions

    private func drop(_ items: [String], into folderID: UUID?, before profileID: UUID? = nil) -> Bool {
        guard items.contains(where: { SidebarModel.DragItem(payload: $0) != nil }) else { return false }
        Task { await model.drop(items, into: folderID, beforeProfile: profileID) }
        return true
    }

    private func ask(_ next: Prompt, text: String = "") { promptText = text; prompt = next }

    private func submit() {
        guard let current = prompt else { return }
        let name = promptText
        prompt = nil
        Task {
            switch current {
            case .newFolder: await model.createFolder(named: name)
            case .renameFolder(let id): await model.renameFolder(id, to: name)
            case .renameProfile(let id): await model.rename(id, to: name)
            }
        }
    }
}

/// The app icon's small form at sidebar size (DS-08): two white bars, the fin and the bulb on the red squircle,
/// drawn from `design/icon` geometry (the 824 squircle at 100,100 in a 1024 grid).
struct KeelMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 824
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 100) * scale, y: (y - 100) * scale) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: point(x, y), size: CGSize(width: w * scale, height: h * scale)) }
            let squircle = Path(roundedRect: rect(100, 100, 824, 824), cornerRadius: 186 * scale, style: .continuous)
            context.fill(
                squircle,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0xEA / 255, green: 0x4A / 255, blue: 0x3E / 255), Color(red: 0xB3 / 255, green: 0x27 / 255, blue: 0x1E / 255)]), startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
            var mark = Path()
            mark.addRoundedRect(in: rect(232, 270, 560, 120), cornerSize: CGSize(width: 60 * scale, height: 60 * scale))
            mark.addRoundedRect(in: rect(342, 430, 340, 120), cornerSize: CGSize(width: 60 * scale, height: 60 * scale))
            mark.addLines([point(477, 550), point(547, 550), point(533, 700), point(491, 700)])
            mark.closeSubpath()
            mark.addEllipse(in: rect(392, 670, 240, 84))
            context.fill(mark, with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}

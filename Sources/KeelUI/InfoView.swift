import AppKit
import KeelCore
import SwiftUI

/// Info mode (board `Info`): four tiles, Databases and Health side by side, and "Show all INFO fields" (FR-SI01).
struct InfoPane: View {
    @ObservedObject var model: InfoModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.circle").font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
                        .accessibilityElement(children: .combine)
                }
                if let overview = model.overview {
                    InfoTiles(tiles: overview.tiles)
                    HStack(alignment: .top, spacing: 48) {
                        InfoDatabases(databases: overview.databases, browse: model.browse)
                        InfoHealth(items: overview.health)
                    }
                    Button(model.showsAll ? "Hide INFO fields" : "Show all INFO fields") { model.showsAll.toggle() }
                        .buttonStyle(.plain).font(Tokens.interface(12.5)).foregroundStyle(Tokens.accent)
                        .accessibilityAddTraits(.isLink)
                    if model.showsAll, let report = model.report { InfoAllFields(report: report, query: $model.rawQuery) }
                } else if model.notice == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).accessibilityLabel("Loading server info")
                }
            }
            .padding(.horizontal, 48).padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.bg)
        // A tab moved between windows can show here before the old window's pane leaves: only that pane may clear it.
        .background(WindowReader { old, new in if new != nil || model.window === old { model.window = new } })
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
    }
}

/// Reports the window the pane is in, for ⌘R (posted with the key window).
private struct WindowReader: NSViewRepresentable {
    /// The window the view left (or nil) and the one it is in now.
    let found: (NSWindow?, NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow?, NSWindow?) -> Void
        private weak var previous: NSWindow?
        init(found: @escaping (NSWindow?, NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) { previous = window }
        override func viewDidMoveToWindow() { found(previous, window) }
    }
}

/// 4 equal columns, 16 apart; `card` tiles with radius 12.
private struct InfoTiles: View {
    let tiles: [InfoTile]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tile.label).font(Tokens.interface(12.5)).foregroundStyle(Tokens.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(tile.value).font(Tokens.interface(30, weight: .semibold)).tracking(-0.6).foregroundStyle(Tokens.fg).lineLimit(1).minimumScaleFactor(0.6)
                        Text(tile.isAvailable ? tile.unit : InfoOverview.unavailable).font(Tokens.interface(13)).foregroundStyle(Tokens.muted).lineLimit(1)
                    }
                    if let fraction = tile.fraction {
                        GeometryReader { proxy in
                            Tokens.track.overlay(alignment: .leading) { Tokens.accent.frame(width: proxy.size.width * fraction) }
                        }
                        .frame(height: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(.top, 6)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.card, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tile.accessibilityLabel)
            }
        }
    }
}

/// A 14/600 heading over 44 px rows with hairlines.
private struct InfoList<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Tokens.interface(14, weight: .semibold)).foregroundStyle(Tokens.fg).padding(.bottom, 12).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct InfoRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }.font(Tokens.interface(13)).frame(height: 44).overlay(alignment: .top) { Tokens.hair.frame(height: 1) }
    }
}

/// One muted line where a list has nothing to show.
private struct InfoEmptyRow: View {
    let text: String

    var body: some View {
        InfoRow {
            Text(text).foregroundStyle(Tokens.muted); Spacer(minLength: 0)
        }
    }
}

/// FR-SI04: keys per database (with expiring keys and avg TTL when some expire), each with Browse.
private struct InfoDatabases: View {
    let databases: [InfoDatabase]
    let browse: (Int) -> Void

    var body: some View {
        InfoList(title: "Databases") {
            if databases.isEmpty {
                InfoEmptyRow(text: "No keys")
            }
            ForEach(databases) { database in
                InfoRow {
                    Text(database.name).font(Tokens.mono(13)).foregroundStyle(Tokens.fg).frame(width: 80, alignment: .leading)
                    Text(database.summary).foregroundStyle(Tokens.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Browse") { browse(database.index) }.buttonStyle(.plain).font(Tokens.interface(12.5)).foregroundStyle(Tokens.accent)
                        .accessibilityLabel("Browse \(database.name)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(database.name), \(database.summary)")
            }
        }
    }
}

private struct InfoHealth: View {
    let items: [InfoHealthItem]

    var body: some View {
        InfoList(title: "Health") {
            ForEach(items) { item in
                InfoRow {
                    Text(item.label).foregroundStyle(Tokens.muted)
                    Spacer(minLength: 8)
                    Text(item.value).foregroundStyle(Tokens.fg).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Every section, "unavailable" for an expected one the server didn't send (FR-SI05), and the searchable Raw view.
private struct InfoAllFields: View {
    let report: InfoReport
    @Binding var query: String
    @State private var raw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("View", selection: $raw) {
                Text("Sections").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            if raw {
                TextField("Search INFO", text: $query).textFieldStyle(.roundedBorder).font(Tokens.interface(12.5)).frame(maxWidth: 320)
                let lines = report.rawLines(matching: query)
                Text(lines.isEmpty ? "No matching lines" : lines.joined(separator: "\n"))
                    .font(Tokens.mono(12)).foregroundStyle(lines.isEmpty ? Tokens.muted : Tokens.fg).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(Tokens.codeBg, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(report.sectionStatuses) { status in
                    InfoList(title: status.title) {
                        switch status {
                        case .unavailable:
                            InfoEmptyRow(text: InfoOverview.unavailable.capitalized)
                        case .available(let section):
                            if section.fields.isEmpty {
                                InfoEmptyRow(text: "No fields")
                            }
                            ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                                InfoRow {
                                    Text(field.name).font(Tokens.mono(12)).foregroundStyle(Tokens.muted).frame(width: 260, alignment: .leading).lineLimit(1)
                                    Text(field.value).font(Tokens.mono(12)).foregroundStyle(Tokens.fg).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 28)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Info's toolbar refresh (FR-SI03): click refreshes (⌘R); the menu picks the auto-refresh interval.
struct InfoRefreshButton: View {
    @ObservedObject var model: InfoModel

    var body: some View {
        Menu {
            Button("Refresh Now") { Task { await model.refresh() } }
            Divider()
            Picker("Auto-Refresh", selection: $model.interval) {
                ForEach(InfoRefreshInterval.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 14)).foregroundStyle(Tokens.muted)
        } primaryAction: {
            Task { await model.refresh() }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 30, height: 30)
        .accessibilityLabel("Refresh")
        .accessibilityValue(model.interval == .off ? "Auto-refresh off" : "Auto-refresh \(model.interval.title.lowercased())")
        .help("Refresh (⌘R); hold for auto-refresh")
    }
}

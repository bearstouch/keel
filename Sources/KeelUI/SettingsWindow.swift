import AppKit
import KeelCore
import SwiftUI

/// The Settings window (⌘,, FR-AP09): General, Browser, Editors, Console, Keyboard and Advanced. One row of panes, one
/// form, Cancel and Apply. Closing the window with unapplied changes is Cancel.
@MainActor
public enum SettingsWindow {
    public static func make(draft: SettingsDraft, keyboard: KeyboardSettingsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(draft: draft, keyboard: keyboard).font(Tokens.interface(13)))
        window.center()
        // The red button, ⌘W and Esc all close the window; each one throws the draft away, so no preview outlives it.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak draft] _ in
            MainActor.assumeIsolated { draft?.cancel() }
        }
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var draft: SettingsDraft
    let keyboard: KeyboardSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            panes
            Tokens.hair.frame(height: 1)
            Group {
                switch draft.pane {
                case .keyboard: KeyboardSettingsView(model: keyboard, bindings: keyboard.bindings)
                default: SettingsForm(draft: draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Tokens.hair.frame(height: 1)
            footer
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(Tokens.sheet)
    }

    /// One row of panes; the selected one on `selection`, and said so to VoiceOver (never by color alone).
    private var panes: some View {
        HStack(spacing: 4) {
            ForEach(SettingsDraft.Pane.allCases, id: \.self) { pane in
                let selected = draft.pane == pane
                Button {
                    draft.pane = pane
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: pane.systemImage).font(.system(size: 16))
                        Text(pane.title).font(Tokens.interface(11.5, weight: selected ? .semibold : .regular))
                    }
                    .frame(width: 76, height: 50)
                    .foregroundStyle(selected ? Tokens.fg : Tokens.muted)
                    .background(selected ? Tokens.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain).accessibilityLabel("Settings panes")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let problem = draft.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Tokens.interface(12)).foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Can't apply: \(problem)")
            } else if draft.pane == .keyboard {
                Text("Shortcuts change as you record them.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            } else {
                Text("New scans and connections use the applied settings.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
            }
            Spacer(minLength: 8)
            // Esc: the window's close, which cancels (`SettingsWindow.make`).
            Button("Cancel") {
                draft.cancel(); NSApp.keyWindow?.performClose(nil)
            }
            .buttonStyle(SheetButtonStyle(primary: false)).keyboardShortcut(.cancelAction)
            .accessibilityHint("Discards the changes not yet applied")
            Button("Apply") { draft.apply() }
                .buttonStyle(SheetButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(!draft.canApply)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// The panes held in the draft. Numbers are chosen from presets (plus a hand-edited value, so it shows as it is), so
/// only the typed separator can be invalid.
struct SettingsForm: View {
    @ObservedObject var draft: SettingsDraft

    var body: some View {
        Form {
            switch draft.pane {
            case .general: general
            case .browser: browser
            case .editors: editors
            case .console: console
            case .advanced: advanced
            case .keyboard: EmptyView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("\(draft.pane.title) settings")
    }

    @ViewBuilder private var general: some View {
        Section {
            Picker("Theme", selection: $draft.document.theme) {
                ForEach(ThemeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Reopen windows and tabs at launch", isOn: $draft.document.restoresWindows).toggleStyle(.switch).tint(Tokens.accent)
            if draft.settings.updatesAvailable {
                Toggle("Check for updates automatically", isOn: $draft.document.checksForUpdates).toggleStyle(.switch).tint(Tokens.accent)
                    .accessibilityHint("Once a day. Updates install only after you confirm.")
            }
        } footer: {
            note("The theme shows as you choose it; Cancel puts back the one in use.")
        }
    }

    @ViewBuilder private var browser: some View {
        Section {
            TextField("Default separator", text: $draft.document.browser.separator).font(Tokens.mono(13))
                .accessibilityHint("Splits key names into folders in the tree. A connection's own separator wins.")
            Picker("Keys per page", selection: $draft.document.browser.pageSize) {
                ForEach(Self.choices([100, 500, 1_000, 5_000, 10_000], including: draft.document.browser.pageSize), id: \.self) {
                    Text(KeyIndexFooter.grouped($0)).tag($0)
                }
            }
            Picker("Auto-page limit", selection: $draft.document.browser.autoPageLimit) {
                ForEach(Self.choices([100_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000], including: draft.document.browser.autoPageLimit), id: \.self) {
                    Text("\(KeyIndexFooter.grouped($0)) keys").tag($0)
                }
            }
        } footer: {
            note("Applies to new scans: connecting, Refresh, a filter or database change. Keys already loaded stay as they are.")
        }
    }

    @ViewBuilder private var editors: some View {
        Section {
            Picker("Default viewer", selection: $draft.document.editors.defaultViewer) {
                ForEach(DefaultViewer.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } footer: {
            note("Automatic opens JSON values as JSON and everything else as Text. A viewer you pick for a key pattern wins for the rest of the session.")
        }
    }

    @ViewBuilder private var console: some View {
        Section {
            Picker("Protocol", selection: $draft.document.console.protocolVersion) {
                ForEach(ConsoleSettings.protocolVersions, id: \.self) { Text("RESP\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            note("Used by consoles opened on new connections. A server without RESP3 always answers in RESP2.")
        }
    }

    @ViewBuilder private var advanced: some View {
        Section {
            Picker("Connect timeout", selection: $draft.document.advanced.connectTimeoutMilliseconds) {
                ForEach(Self.choices([1_000, 3_000, 5_000, 10_000, 30_000, 60_000], including: draft.document.advanced.connectTimeoutMilliseconds), id: \.self) {
                    Text(Self.duration($0)).tag($0)
                }
            }
            Picker("Command timeout", selection: $draft.document.advanced.commandTimeoutMilliseconds) {
                ForEach(Self.choices([5_000, 10_000, 30_000, 60_000, 120_000, 300_000], including: draft.document.advanced.commandTimeoutMilliseconds), id: \.self) {
                    Text(Self.duration($0)).tag($0)
                }
            }
            Toggle("Identify as “keel” (CLIENT SETNAME)", isOn: $draft.document.advanced.setsClientName).toggleStyle(.switch).tint(Tokens.accent)
        } footer: {
            note("Used by new connections whose profile doesn't set its own timeouts.")
        }
    }

    private func note(_ text: String) -> some View { Text(text).font(Tokens.interface(12)).foregroundStyle(Tokens.muted) }

    /// The presets, with `value` added in order when a hand-edited file holds another one.
    static func choices(_ presets: [Int], including value: Int) -> [Int] { presets.contains(value) ? presets : (presets + [value]).sorted() }

    /// "500 ms", "10 s", "2 min".
    static func duration(_ milliseconds: Int) -> String {
        if milliseconds % 60_000 == 0 { return "\(milliseconds / 60_000) min" }
        if milliseconds % 1_000 == 0 { return "\(milliseconds / 1_000) s" }
        return "\(milliseconds) ms"
    }
}

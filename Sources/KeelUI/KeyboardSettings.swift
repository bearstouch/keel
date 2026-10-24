import AppKit
import Combine
import KeelCore
import SwiftUI

/// Settings → Keyboard (FR-AP02): every rebindable command with its shortcut, and the fixed ones read-only. Click a
/// shortcut, then press the new chord: Esc cancels, ⌫ alone clears it. A rejected chord (a conflict, no ⌘, a reserved
/// system shortcut) leaves the binding as it was and says why, naming the command that already has it.
@MainActor
public final class KeyboardSettingsModel: ObservableObject {
    public let bindings: ShortcutBindings
    /// The command waiting for its new chord.
    @Published public private(set) var recording: KeelShortcut?
    /// Why the last chord was rejected; cleared by the next change.
    @Published public private(set) var message: String?
    private var monitor: Any?
    /// The window the recording started in (Settings); a key press in any other window ends the recording instead.
    private weak var recordingWindow: NSWindow?

    public init(bindings: ShortcutBindings) { self.bindings = bindings }

    isolated deinit { stopMonitor() }

    public func startRecording(_ action: KeelShortcut) {
        recording = action; message = nil
        guard NSApp != nil else { return }
        recordingWindow = NSApp.keyWindow
        guard monitor == nil else { return }
        // Before the menus see the press, so recording ⌘R doesn't also refresh the key window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    public func cancelRecording() { recording = nil; recordingWindow = nil; stopMonitor() }

    /// The pressed chord for the command being recorded. Returns whether it was taken.
    @discardableResult
    public func record(_ chord: KeyChord?) -> Bool {
        guard let action = recording else { return false }
        cancelRecording()
        return apply(to: action) { () throws(KeelShortcutIssue) in try bindings.bind(action, to: chord) }
    }

    public func clear(_ action: KeelShortcut) { _ = apply(to: action) { () throws(KeelShortcutIssue) in try bindings.bind(action, to: nil) } }

    public func restoreDefault(_ action: KeelShortcut) { _ = apply(to: action) { () throws(KeelShortcutIssue) in try bindings.restoreDefault(action) } }

    public func restoreAllDefaults() { cancelRecording(); message = nil; bindings.restoreAllDefaults() }

    private func apply(to action: KeelShortcut, _ change: () throws(KeelShortcutIssue) -> Void) -> Bool {
        do throws(KeelShortcutIssue) {
            try change()
            message = nil
            return true
        } catch {
            message = error.rejection(for: action)
            return false
        }
    }

    /// Esc cancels and ⌫ alone clears; anything else is the chord. A bare modifier or an unbindable key is swallowed
    /// while recording, so it never reaches the window.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording != nil else { return false }
        // The user moved on to another window (or closed Settings): its key press is its own, not the new chord.
        guard event.window === recordingWindow else { cancelRecording(); return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { cancelRecording(); return true }  // Esc
        if event.keyCode == 51, flags.isEmpty { record(nil); return true }  // ⌫
        if let chord = KeyChord(event: event) { record(chord) }
        return true
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The Settings window (⌘,). KEEL-049 adds its other panes; Keyboard is the first.
@MainActor
public enum SettingsWindow {
    public enum Pane: String, CaseIterable, Sendable {
        case keyboard

        public var title: String { "Keyboard" }
    }

    public static func make(model: KeyboardSettingsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keyboard"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KeyboardSettingsView(model: model, bindings: model.bindings))
        window.center()
        return window
    }
}

struct KeyboardSettingsView: View {
    @ObservedObject var model: KeyboardSettingsModel
    @ObservedObject var bindings: ShortcutBindings

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(KeelShortcut.Menu.allCases, id: \.self) { menu in
                    Section(menu.rawValue) {
                        ForEach(KeelShortcut.allCases.filter { $0.menu == menu }, id: \.self) { action in row(action) }
                    }
                }
                Section("Can't be changed") {
                    ForEach(KeelShortcut.fixed, id: \.title) { item in
                        HStack {
                            Text(item.title).foregroundStyle(Tokens.muted)
                            Spacer()
                            Label(item.chord.description, systemImage: "lock").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.title), \(item.chord.description), can't be changed")
                    }
                }
            }
            Tokens.hair.frame(height: 1)
            HStack(spacing: 12) {
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle").font(Tokens.interface(12)).foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Shortcut not changed: \(message)")
                } else {
                    Text("Every shortcut must include ⌘.").font(Tokens.interface(12)).foregroundStyle(Tokens.muted)
                }
                Spacer(minLength: 8)
                Button("Restore Defaults") { model.restoreAllDefaults() }.disabled(bindings.map == .defaults)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Tokens.bg)
        .onDisappear { model.cancelRecording() }
    }

    private func row(_ action: KeelShortcut) -> some View {
        let chord = bindings[action], isRecording = model.recording == action
        return HStack(spacing: 8) {
            Text(action.title).foregroundStyle(Tokens.fg)
            if KeelShortcut.notYetAvailable.contains(action) { Text("Not available yet").font(Tokens.interface(11)).foregroundStyle(Tokens.muted) }
            Spacer()
            if chord != action.defaultChord {
                Button {
                    model.restoreDefault(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless).help("Restore Default").accessibilityLabel("Restore default shortcut for \(action.title)")
            }
            Button(isRecording ? "Type shortcut…" : chord?.description ?? "None") {
                if isRecording { model.cancelRecording() } else { model.startRecording(action) }
            }
            .font(Tokens.interface(12))
            .frame(minWidth: 110)
            .accessibilityLabel("\(action.title) shortcut, \(isRecording ? "recording, press the new shortcut or Escape to cancel" : chord?.description ?? "none")")
            .accessibilityHint("Press to record a new shortcut; Delete clears it")
        }
    }
}

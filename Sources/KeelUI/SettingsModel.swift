import AppKit
import Combine
import KeelCore

extension ThemeChoice {
    /// The appearance `NSApp` takes: nil follows macOS, live (DS-11).
    public var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

/// The single owner of `settings.json` (02 Architecture → Persistence) and the app's appearance: the applied settings
/// of every pane (FR-AP09), the theme (FR-AP04) and the Increase Contrast flag the tokens read. A theme change only
/// sets the app's appearance, so every window, sheet and the console chrome repaint at once while sessions,
/// connections and loaded keys stay as they are. Code off the main actor reads the applied settings from `snapshot`.
@MainActor
public final class SettingsModel: ObservableObject {
    /// What is in effect (and, once loaded, saved). The Settings window edits a `SettingsDraft`, never this.
    @Published public private(set) var applied = SettingsDocument()
    /// `applied`, readable from any actor: new scans and new connections read it.
    public let snapshot = SettingsSnapshot()

    public var theme: ThemeChoice { applied.theme }
    /// This build has an updater (a packaged build with a feed, FR-AP07); General shows the update toggle only then.
    public var updatesAvailable = false

    /// What changed before `settings.json` was read, and so wins over the file: the theme alone (View → Theme), or the
    /// whole document (an Apply).
    private enum EarlyChange { case theme, all }

    private let persistence: Persistence<SettingsDocument>?
    private let applyAppearance: (NSAppearance?) -> Void
    private let systemIsDark: () -> Bool
    private var loaded = false
    private var earlyChange: EarlyChange?
    private var sequence: UInt64 = 0
    /// Something changed this run, so quitting writes it (an untouched setup leaves no `settings.json` behind).
    private var dirty = false
    /// The theme on screen: the applied one, or a Settings draft's preview.
    private var shownTheme = ThemeChoice.default
    /// Before the first `show` the app is on macOS's appearance, not on `shownTheme`.
    private var appearanceSet = false

    /// `applyAppearance` sets `NSApp.appearance` and `systemIsDark` reads the app's effective one; tests inject both.
    public init(
        persistence: Persistence<SettingsDocument>?, applyAppearance: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 },
        systemIsDark: @escaping () -> Bool = { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    ) {
        self.persistence = persistence; self.applyAppearance = applyAppearance; self.systemIsDark = systemIsDark
    }

    /// Applies Light at once, so the first window never flashes the system appearance, then the saved settings. A file
    /// that needs recovery keeps the defaults for this run and is never written over (Persistence refuses).
    public func load() async {
        show(applied.theme)
        let result = await persistence?.load()
        loaded = true
        var next = applied
        if case .loaded(let document)? = result {
            switch earlyChange {
            case nil: next = document
            case .theme?: next = document; next.theme = applied.theme
            case .all?: break
            }
        }
        set(next)
        if earlyChange != nil { save() }
    }

    /// View → Theme (FR-AP04): applied and saved at once, outside any Settings draft.
    public func setTheme(_ choice: ThemeChoice) {
        guard choice != applied.theme else { return }
        var next = applied
        next.theme = choice
        set(next)
        if loaded { save() } else if earlyChange == nil { earlyChange = .theme }
    }

    /// The Settings window's Apply: the draft becomes the applied settings and is saved. New scans and connections
    /// read it from then on; open ones keep what they started with.
    public func apply(_ document: SettingsDocument) {
        guard document != applied else { show(document.theme); return }
        set(document)
        if loaded { save() } else { earlyChange = .all }
    }

    /// A Settings draft's theme, shown live but neither applied nor saved; `endPreview()` shows the applied one again.
    public func preview(theme: ThemeChoice) { show(theme) }

    public func endPreview() { show(applied.theme) }

    /// Increase Contrast changed in System Settings (or at launch). The flag is read while colors resolve; re-applying
    /// the appearance makes AppKit and SwiftUI resolve every dynamic color again, layer colors included.
    public func accessibilityDisplayOptionsChanged(increasesContrast: Bool) {
        guard increasesContrast != KeelTheme.increasesContrast else { return }
        KeelTheme.increasesContrast = increasesContrast
        // Assigning the same appearance is a no-op, so pass through the opposite one in the same turn: no frame is drawn
        // in between, but every view sees an appearance change.
        let isDark = shownTheme == .system ? systemIsDark() : shownTheme == .dark
        applyAppearance(NSAppearance(named: isDark ? .aqua : .darkAqua))
        applyAppearance(shownTheme.appearance)
    }

    private func set(_ document: SettingsDocument) {
        applied = document
        snapshot.current = document
        show(document.theme)
    }

    /// Sets the app's appearance, unless it already shows `theme` (re-applying it would repaint for nothing).
    private func show(_ theme: ThemeChoice) {
        guard theme != shownTheme || !appearanceSet else { return }
        appearanceSet = true; shownTheme = theme
        applyAppearance(theme.appearance)
    }

    private func save() {
        guard let persistence else { return }
        dirty = true
        sequence += 1
        let document = applied, sequence = sequence
        Task { await persistence.scheduleSave(document, sequence: sequence) }
    }

    /// On quit: the latest settings are written now rather than after the debounce. The document is handed over here
    /// too, since the save `save()` scheduled may not have reached the actor yet.
    public func flush() async {
        guard loaded, dirty, let persistence else { return }
        sequence += 1
        await persistence.scheduleSave(applied, sequence: sequence)
        try? await persistence.flush()
    }
}

/// The Settings window's edits (FR-AP09): a copy of the applied settings that Apply makes current and Cancel throws
/// away, restoring the exact prior state. The theme is previewed live while chosen; nothing is saved before Apply.
/// Keyboard bindings aren't part of it: they apply and save as they are recorded (FR-AP02).
@MainActor
public final class SettingsDraft: ObservableObject {
    public enum Pane: String, CaseIterable, Sendable {
        case general, browser, editors, console, keyboard, advanced

        public var title: String { rawValue.capitalized }

        public var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .browser: "list.bullet.indent"
            case .editors: "doc.text"
            case .console: "terminal"
            case .keyboard: "keyboard"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    @Published public var document: SettingsDocument {
        didSet { if document.theme != oldValue.theme { settings.preview(theme: document.theme) } }
    }
    @Published public var pane = Pane.general
    public let settings: SettingsModel

    public init(settings: SettingsModel) {
        self.settings = settings
        document = settings.applied
    }

    /// Something differs from the applied settings.
    public var hasChanges: Bool { document != settings.applied }

    /// Why Apply is refused, naming the field; nil when the draft can be applied. Pickers can only hold valid
    /// values, so only the typed separator can be wrong.
    public var problem: String? {
        BrowserSettings.isValidSeparator(document.browser.separator) ? nil : "The separator must be 1 to 4 bytes, without control characters."
    }

    public var canApply: Bool { hasChanges && problem == nil }

    /// Starts from the applied settings when the window opens again: View → Theme may have changed them while it was closed.
    public func begin() { document = settings.applied }

    /// Apply: returns false, changing nothing, while `problem` says why.
    @discardableResult
    public func apply() -> Bool {
        guard problem == nil else { return false }
        settings.apply(document)
        return true
    }

    /// Cancel (or closing the window): the draft and the appearance go back to the applied settings; nothing is saved.
    public func cancel() {
        document = settings.applied
        settings.endPreview()
    }
}

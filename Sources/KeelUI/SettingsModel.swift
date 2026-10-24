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

/// The single owner of `settings.json` (02 Architecture → Persistence) and the app's appearance: the theme (FR-AP04)
/// and the Increase Contrast flag the tokens read. A theme change only sets the app's appearance, so every window,
/// sheet and the console chrome repaint at once while sessions, connections and loaded keys stay as they are (AC4).
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public private(set) var theme: ThemeChoice = .default

    private let persistence: Persistence<SettingsDocument>?
    private let applyAppearance: (NSAppearance?) -> Void
    private let systemIsDark: () -> Bool
    private var loaded = false
    /// A theme picked while the file was still being read wins over the saved one.
    private var changedBeforeLoad = false
    private var sequence: UInt64 = 0
    /// The document as loaded, so a save changes only what this model edits and keeps the rest of the file's fields.
    private var saved = SettingsDocument()
    /// Something changed this run, so quitting writes it (an untouched setup leaves no `settings.json` behind).
    private var dirty = false

    /// `applyAppearance` sets `NSApp.appearance` and `systemIsDark` reads the app's effective one; tests inject both.
    public init(
        persistence: Persistence<SettingsDocument>?, applyAppearance: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 },
        systemIsDark: @escaping () -> Bool = { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    ) {
        self.persistence = persistence; self.applyAppearance = applyAppearance; self.systemIsDark = systemIsDark
    }

    /// Applies Light at once, so the first window never flashes the system appearance, then the saved theme. A file
    /// that needs recovery keeps the default for this run and is never written over (Persistence refuses).
    public func load() async {
        applyAppearance(theme.appearance)
        let result = await persistence?.load()
        loaded = true
        if case .loaded(let document)? = result { saved = document }
        if changedBeforeLoad { save(); return }
        guard case .loaded? = result, saved.theme != theme else { return }
        theme = saved.theme
        applyAppearance(theme.appearance)
    }

    public func setTheme(_ choice: ThemeChoice) {
        guard choice != theme else { return }
        theme = choice
        applyAppearance(choice.appearance)
        if loaded { save() } else { changedBeforeLoad = true }
    }

    /// Increase Contrast changed in System Settings (or at launch). The flag is read while colors resolve; re-applying
    /// the appearance makes AppKit and SwiftUI resolve every dynamic color again, layer colors included.
    public func accessibilityDisplayOptionsChanged(increasesContrast: Bool) {
        guard increasesContrast != KeelTheme.increasesContrast else { return }
        KeelTheme.increasesContrast = increasesContrast
        // Assigning the same appearance is a no-op, so pass through the opposite one in the same turn: no frame is drawn
        // in between, but every view sees an appearance change.
        let isDark = theme == .system ? systemIsDark() : theme == .dark
        applyAppearance(NSAppearance(named: isDark ? .aqua : .darkAqua))
        applyAppearance(theme.appearance)
    }

    public var document: SettingsDocument {
        var document = saved
        document.theme = theme
        return document
    }

    private func save() {
        guard let persistence else { return }
        dirty = true
        sequence += 1
        let document = document, sequence = sequence
        Task { await persistence.scheduleSave(document, sequence: sequence) }
    }

    /// On quit: the latest settings are written now rather than after the debounce. The document is handed over here
    /// too, since the save `save()` scheduled may not have reached the actor yet.
    public func flush() async {
        guard loaded, dirty, let persistence else { return }
        sequence += 1
        await persistence.scheduleSave(document, sequence: sequence)
        try? await persistence.flush()
    }
}

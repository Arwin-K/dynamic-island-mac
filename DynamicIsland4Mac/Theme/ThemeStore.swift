import AppKit
import Observation
import SwiftUI

/// Owns the active theme and the system state that affects how it renders (dark mode,
/// Reduce Motion, Increase Contrast, the live accent color).
///
/// Settings edits go through `update(_:)`: the island redraws immediately (live preview)
/// and the theme file is written shortly after the last change.
@MainActor
@Observable
final class ThemeStore {
    /// The theme being drawn.
    private(set) var theme: Theme = .default
    let library: ThemeLibrary

    private(set) var systemIsDark: Bool = true
    private(set) var reduceMotion: Bool = false
    private(set) var increaseContrast: Bool = false

    // Live accent sources. Only the one the theme uses is kept up to date.
    private(set) var systemAccent: HexColor = HexColor(nsColor: .controlAccentColor)
    private(set) var wallpaperAccent: HexColor?
    /// Set by the Now Playing module when artwork changes.
    var albumArtAccent: HexColor?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var wallpaperCache: (key: String, color: HexColor?)?
    @ObservationIgnored private var onActiveThemeChanged: ((String) -> Void)?

    init(library: ThemeLibrary? = nil) {
        self.library = library ?? ThemeLibrary(directory: AppPaths.isRunningTests ? nil : AppPaths.themesDirectory)
        refreshSystemState()
    }

    // MARK: - Activation and editing

    /// Activates the theme with `id` (falls back to the first built-in).
    func activate(id: String) {
        flushPendingSave()
        let next = library.theme(id: id) ?? library.builtIns.first ?? .default
        theme = next
        onActiveThemeChanged?(next.id)
        refreshAccentSource()
    }

    /// Edit the active theme. The change shows immediately; the file is written after 0.5 s
    /// of quiet so dragging a slider doesn't hammer the disk.
    func update(_ change: (inout Theme) -> Void) {
        var next = theme
        change(&next)
        guard next != theme else { return }
        let sourceChanged = next.colors.accentSource != theme.colors.accentSource || next.colors.sampleStyle != theme.colors.sampleStyle
        theme = next
        if sourceChanged { refreshAccentSource() }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.library.save(self.theme)
            self.saveTask = nil
        }
    }

    /// Replace the whole active theme (reset, import).
    func replace(with newTheme: Theme) {
        saveTask?.cancel()
        theme = newTheme
        onActiveThemeChanged?(newTheme.id)
        refreshAccentSource()
    }

    func flushPendingSave() {
        guard let task = saveTask else { return }
        task.cancel()
        saveTask = nil
        library.save(theme)
    }

    /// Hook up persistence of the active theme id and start watching the user folder.
    func start(activeID: String, onActiveThemeChanged: @escaping (String) -> Void) {
        self.onActiveThemeChanged = onActiveThemeChanged
        activate(id: activeID)
        library.onUserThemesChanged = { [weak self] in
            guard let self else { return }
            // Someone edited the active theme's file outside the app: pick it up live.
            if let fresh = self.library.theme(id: self.theme.id), fresh != self.theme, self.saveTask == nil {
                self.theme = fresh
                self.refreshAccentSource()
            } else if self.library.theme(id: self.theme.id) == nil {
                self.activate(id: self.library.builtIns.first?.id ?? "stealth")
            }
        }
        library.startWatching()
        startObservingSystem()
    }

    // MARK: - Derived values

    var isDark: Bool {
        switch theme.appearance {
        case .system: systemIsDark
        case .dark: true
        case .light: false
        }
    }

    /// The accent from the theme's live source, or nil to use the fixed accent.
    var liveAccent: HexColor? {
        switch theme.colors.accentSource {
        case .fixed: nil
        case .system: systemAccent
        case .wallpaper: wallpaperAccent
        case .albumArt: albumArtAccent
        }
    }

    var palette: ResolvedPalette {
        ResolvedPalette(theme: theme, isDark: isDark, accentOverride: liveAccent, increaseContrast: increaseContrast)
    }

    var animation: Animation? { theme.motion.animation(reduceMotion: reduceMotion) }
    var settleDuration: Double { theme.motion.settleDuration(reduceMotion: reduceMotion) }

    // MARK: - System observation (all event driven)

    private func startObservingSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemState() }
        })
        // Wallpaper can change per Space and after wake; there is no public "wallpaper
        // changed" notification, so re-sample on these (cheap: cached by file + date).
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWallpaperIfNeeded() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpaperIfNeeded() }
        })
        // Posted when the user changes the accent color in System Settings.
        observers.append(NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemAccent = HexColor(nsColor: .controlAccentColor) }
        })
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshSystemState() }
        }
    }

    func refreshSystemState() {
        let ws = NSWorkspace.shared
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        systemIsDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        systemAccent = HexColor(nsColor: .controlAccentColor)
    }

    private func refreshAccentSource() {
        if theme.colors.accentSource == .wallpaper { refreshWallpaperIfNeeded(force: true) }
    }

    /// Re-sample the desktop picture of the main display, off the main thread.
    func refreshWallpaperIfNeeded(force: Bool = false) {
        guard theme.colors.accentSource == .wallpaper,
              let screen = NSScreen.screens.first(where: { $0.hasNotch }) ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let style = theme.colors.sampleStyle
        let key = "\(url.path)|\(modified.timeIntervalSince1970)|\(style.rawValue)"
        if !force, wallpaperCache?.key == key { return }
        if let cached = wallpaperCache, cached.key == key {
            wallpaperAccent = cached.color
            return
        }
        Task.detached(priority: .utility) {
            let color = ColorSampler.color(fromImageAt: url, style: style)
            await MainActor.run { [weak self] in
                self?.wallpaperCache = (key, color)
                self?.wallpaperAccent = color
            }
        }
    }
}

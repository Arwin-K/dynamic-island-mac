import Observation
import SwiftUI

/// A feature that shows up in the island. Everything the island displays comes from a module:
/// Now Playing, agent sessions, battery, calendar… and yours.
///
/// Make your module an `@Observable` class so the island redraws when its data changes,
/// implement the three views, and register it in `ModuleRegistry.swift`. That's all.
///
/// * `compactLeading` / `compactTrailing` sit to the left and right of the notch when your
///   module owns the compact state. Keep them about 24 pt tall and narrow.
/// * `expanded` fills the panel below the notch when the user opens the island.
/// * `isActive` means "I have a live activity right now". When several modules are active,
///   the one highest in the user's order (Settings → Modules) gets the compact slot; the user
///   can swipe sideways on the island to cycle through the others.
///
/// See `Modules/Battery/BatteryModule.swift` for a complete, small example, and the README
/// section "Write your own module in 5 minutes".
@MainActor
protocol IslandModule: AnyObject, Identifiable where ID == String {
    associatedtype CompactLeading: View
    associatedtype CompactTrailing: View
    associatedtype Expanded: View

    /// Stable id, used in preferences and theme files. Lowercase, no spaces.
    var id: String { get }
    var displayName: String { get }
    /// SF Symbol for Settings and the expanded tab bar.
    var symbolName: String { get }
    /// Default position in the priority order (lower = higher priority). Users can reorder.
    var priority: Int { get }
    /// Whether the module starts enabled for new users. Opt-in features return false.
    var enabledByDefault: Bool { get }
    /// Has something to show in the compact state right now.
    var isActive: Bool { get }
    /// Shows a tab in the expanded view even when not active (e.g. Battery, File Shelf).
    var showsInExpandedWhenIdle: Bool { get }
    /// Ask for a taller expanded panel (points below the notch) while showing this module,
    /// e.g. while something needs a decision. `nil` uses the theme's height.
    var preferredExpandedHeight: Double? { get }
    /// Width of each side of the compact island while this module owns it (points beside the
    /// notch). `nil` uses the theme's `compactSideWidth`.
    var preferredCompactSideWidth: Double? { get }

    @ViewBuilder func compactLeading() -> CompactLeading
    @ViewBuilder func compactTrailing() -> CompactTrailing
    @ViewBuilder func expanded() -> Expanded

    /// Module-specific settings, shown in Settings → Modules.
    func settingsView() -> AnyView

    /// Called when the module is enabled (and at launch if enabled). Subscribe to things here.
    func start()
    /// Called when the module is disabled. Unsubscribe and stop timers here.
    func stop()
}

extension IslandModule {
    var symbolName: String { "square.dashed" }
    var priority: Int { 100 }
    var enabledByDefault: Bool { true }
    var showsInExpandedWhenIdle: Bool { false }
    var preferredExpandedHeight: Double? { nil }
    var preferredCompactSideWidth: Double? { nil }
    func settingsView() -> AnyView { AnyView(EmptyView()) }
    func start() {}
    func stop() {}
}

/// Type-erased module, so the registry can hold different module types in one array.
/// Built from closures that capture the concrete module; module authors never touch this.
@MainActor
final class AnyIslandModule: Identifiable {
    let id: String
    let displayName: String
    let symbolName: String
    let priority: Int
    let enabledByDefault: Bool
    let base: AnyObject

    private let _isActive: () -> Bool
    private let _showsWhenIdle: () -> Bool
    private let _preferredHeight: () -> Double?
    private let _preferredSideWidth: () -> Double?
    private let _compactLeading: () -> AnyView
    private let _compactTrailing: () -> AnyView
    private let _expanded: () -> AnyView
    private let _settings: () -> AnyView
    private let _start: () -> Void
    private let _stop: () -> Void

    init<M: IslandModule>(_ module: M) {
        id = module.id
        displayName = module.displayName
        symbolName = module.symbolName
        priority = module.priority
        enabledByDefault = module.enabledByDefault
        base = module
        _isActive = { module.isActive }
        _showsWhenIdle = { module.showsInExpandedWhenIdle }
        _preferredHeight = { module.preferredExpandedHeight }
        _preferredSideWidth = { module.preferredCompactSideWidth }
        _compactLeading = { AnyView(module.compactLeading()) }
        _compactTrailing = { AnyView(module.compactTrailing()) }
        _expanded = { AnyView(module.expanded()) }
        _settings = { module.settingsView() }
        _start = { module.start() }
        _stop = { module.stop() }
    }

    var isActive: Bool { _isActive() }
    var showsInExpandedWhenIdle: Bool { _showsWhenIdle() }
    var preferredExpandedHeight: Double? { _preferredHeight() }
    var preferredCompactSideWidth: Double? { _preferredSideWidth() }
    func compactLeading() -> AnyView { _compactLeading() }
    func compactTrailing() -> AnyView { _compactTrailing() }
    func expanded() -> AnyView { _expanded() }
    func settingsView() -> AnyView { _settings() }
    func start() { _start() }
    func stop() { _stop() }
}

/// A brief attention-grabbing message from a module.
struct IslandAlert: Identifiable {
    let id = UUID()
    var moduleID: String
    let content: AnyView
    var feedback: FeedbackEvent?
    /// Seconds to show; `nil` uses the theme's alert duration.
    var duration: TimeInterval?
    /// Stays up until dismissed (used by permission prompts).
    var sticky: Bool = false
    /// A key that lets a newer alert replace a queued or showing one (e.g. one per agent session).
    var coalescingKey: String?
}

/// What a module can do with the rest of the app. Each module gets its own context,
/// created by `ModuleRegistry`.
@MainActor
final class ModuleContext {
    var moduleID: String
    unowned let services: AppServices
    /// Preview modules (Settings → Appearance) get a context that never shows alerts.
    let isPreview: Bool
    /// The app's module manager (nil in previews, which never alert).
    var manager: ModuleManager? { isPreview ? nil : services.moduleManager }

    init(moduleID: String, services: AppServices, isPreview: Bool = false) {
        self.moduleID = moduleID
        self.services = services
        self.isPreview = isPreview
    }

    var theme: Theme { services.themeStore.theme }

    /// Show an alert. Plays the theme's sound / haptic for `feedback` if enabled.
    func alert(feedback: FeedbackEvent? = nil, duration: TimeInterval? = nil, sticky: Bool = false,
               coalescingKey: String? = nil, @ViewBuilder content: () -> some View) {
        guard !isPreview else { return }
        manager?.present(IslandAlert(moduleID: moduleID, content: AnyView(content()), feedback: feedback,
                                     duration: duration, sticky: sticky, coalescingKey: coalescingKey))
    }

    func dismissAlerts(coalescingKey: String? = nil) {
        manager?.dismissAlerts(moduleID: moduleID, coalescingKey: coalescingKey)
    }

    /// Open the island on this module (e.g. to show something that needs a decision).
    func openIsland() {
        guard !isPreview else { return }
        manager?.select(moduleID)
        services.screenManager.primaryIsland?.open(pinned: true)
    }

    func closeIsland() {
        services.islands.forEach { if $0.state == .expanded { $0.close() } }
    }

    // MARK: Settings storage (no persistence code needed in modules)

    private var settings: [String: String] { services.preferences.values.moduleSettings[moduleID] ?? [:] }

    func string(_ key: String, default value: String) -> String { settings[key] ?? value }
    func bool(_ key: String, default value: Bool) -> Bool { settings[key].map { $0 == "true" } ?? value }
    func double(_ key: String, default value: Double) -> Double { settings[key].flatMap(Double.init) ?? value }

    func set(_ key: String, _ value: String) {
        services.preferences.update { $0.moduleSettings[moduleID, default: [:]][key] = value }
    }
    func set(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }
    func set(_ key: String, _ value: Double) { set(key, String(value)) }

    func boolBinding(_ key: String, default value: Bool) -> Binding<Bool> {
        Binding(get: { self.bool(key, default: value) }, set: { self.set(key, $0) })
    }
    func doubleBinding(_ key: String, default value: Double) -> Binding<Double> {
        Binding(get: { self.double(key, default: value) }, set: { self.set(key, $0) })
    }
    func stringBinding(_ key: String, default value: String) -> Binding<String> {
        Binding(get: { self.string(key, default: value) }, set: { self.set(key, $0) })
    }
}

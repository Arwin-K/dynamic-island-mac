import AppKit
import Observation

/// The app's object graph, created once. Views and modules reach shared services through
/// here instead of scattered singletons, which keeps it obvious what depends on what.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let preferences: PreferencesStore
    let themeStore: ThemeStore
    private(set) lazy var screenManager = ScreenManager(services: self)
    private(set) lazy var hotKey = HotKeyController(services: self)
    private(set) lazy var agentHub = AgentHub(services: self)
    private(set) lazy var moduleManager = ModuleManager(services: self, modules: ModuleRegistry.makeModules(services: self))

    init(preferences: PreferencesStore? = nil, themeStore: ThemeStore? = nil) {
        self.preferences = preferences ?? PreferencesStore()
        self.themeStore = themeStore ?? ThemeStore()
    }

    /// Called once from `applicationDidFinishLaunching` (never in unit tests).
    func start() {
        themeStore.start(activeID: preferences.values.activeThemeID) { [weak self] id in
            self?.preferences.update { $0.activeThemeID = id }
        }
        agentHub.start()
        moduleManager.start()
        screenManager.start()
        hotKey.start()
        Log.app.info("DynamicIsland4Mac started")
        #if DEBUG
        applyDebugPreviewState()
        #endif
    }

    #if DEBUG
    /// Debug builds only: `open DynamicIsland4Mac.app --args -DI4MPreviewState expanded` forces
    /// every island into a state, and `-DI4MOpenSettings appearance` opens a Settings pane,
    /// for screenshots and for checking layouts without a mouse.
    private func applyDebugPreviewState() {
        if let pane = UserDefaults.standard.string(forKey: "DI4MOpenSettings").flatMap(SettingsPane.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SettingsOpener.open(pane) }
        }
        guard let raw = UserDefaults.standard.string(forKey: "DI4MPreviewState"),
              let state = IslandState(rawValue: raw) else { return }
        Log.app.debug("Debug preview state: \(raw, privacy: .public), islands: \(self.islands.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // -DI4MPreviewModule <id> picks the page; -DI4MStartFocus YES starts a focus session.
            if let module = UserDefaults.standard.string(forKey: "DI4MPreviewModule") { self?.moduleManager.select(module) }
            if UserDefaults.standard.bool(forKey: "DI4MStartFocus"),
               let focus = self?.moduleManager.module(id: "focusTimer")?.base as? FocusTimerModule {
                self?.moduleManager.setEnabled("focusTimer", true)
                focus.beginSession()
            }
            for island in self?.islands ?? [] {
                switch state {
                case .expanded: island.open(pinned: true)
                case .alert: island.beginAlert()
                case .compact: island.setLiveActivity(true)
                case .collapsed: break
                }
            }
        }
    }
    #endif

    /// Stop child processes and flush state. Called on quit and on SIGTERM / SIGINT.
    func shutdown() {
        themeStore.flushPendingSave()
        preferences.saveNow()
        for module in moduleManager.modules { module.stop() }
        agentHub.stop()
    }

    /// Islands were added or removed (screen change).
    func islandsDidChange() {
        moduleManager.syncIslands()
    }

    var islands: [IslandViewModel] { screenManager.islands }
}

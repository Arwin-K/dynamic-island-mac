import Observation
import SwiftUI

/// Owns every module: which are enabled, their priority order, which one has the compact
/// slot, which one the expanded view shows, and the alert queue. Shared by all islands, so
/// every display shows the same thing.
@MainActor
@Observable
final class ModuleManager {
    let isPreview: Bool
    private(set) var modules: [AnyIslandModule]
    /// The module the user picked for compact (by swiping) or in the expanded tab bar.
    private(set) var selectedModuleID: String?
    private(set) var currentAlert: IslandAlert?

    @ObservationIgnored private unowned let services: AppServices
    @ObservationIgnored private var queue: [IslandAlert] = []
    @ObservationIgnored private var alertWork: DispatchWorkItem?
    @ObservationIgnored private var started: Set<String> = []

    init(services: AppServices, modules: [AnyIslandModule], isPreview: Bool = false) {
        self.services = services
        self.modules = modules
        self.isPreview = isPreview
    }

    private var preferences: Preferences { services.preferences.values }

    // MARK: - Order and enablement

    /// All modules in the user's priority order.
    var ordered: [AnyIslandModule] {
        let order = preferences.moduleOrder
        return modules.sorted { a, b in
            let ia = order.firstIndex(of: a.id), ib = order.firstIndex(of: b.id)
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.priority < b.priority
            }
        }
    }

    func isEnabled(_ module: AnyIslandModule) -> Bool {
        isPreview || (preferences.moduleEnabled[module.id] ?? module.enabledByDefault)
    }

    func module(id: String) -> AnyIslandModule? { modules.first { $0.id == id } }

    var enabled: [AnyIslandModule] { ordered.filter(isEnabled) }
    var active: [AnyIslandModule] { enabled.filter(\.isActive) }
    var hasLiveActivity: Bool { !active.isEmpty }

    /// The module shown in the compact state.
    var compactModule: AnyIslandModule? {
        let active = active
        if let id = selectedModuleID, let m = active.first(where: { $0.id == id }) { return m }
        return active.first
    }

    /// Tabs in the expanded view: active modules first (in priority order), then idle ones
    /// that always show (Battery, File Shelf…).
    var expandedTabs: [AnyIslandModule] {
        let enabled = enabled
        return enabled.filter(\.isActive) + enabled.filter { !$0.isActive && $0.showsInExpandedWhenIdle }
    }

    var expandedModule: AnyIslandModule? {
        let tabs = expandedTabs
        if let id = selectedModuleID, let m = tabs.first(where: { $0.id == id }) { return m }
        return compactModule ?? tabs.first
    }

    func select(_ id: String?) {
        withAnimation(services.themeStore.animation) { selectedModuleID = id }
    }

    /// Swipe on the compact island: move to the next/previous active module.
    func cycleCompact(by step: Int) {
        let active = active
        guard active.count > 1 else { return }
        let index = active.firstIndex { $0.id == compactModule?.id } ?? 0
        let next = (index + step + active.count) % active.count
        select(active[next].id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        services.preferences.update { $0.moduleEnabled[id] = enabled }
    }

    func move(from source: IndexSet, to destination: Int) {
        var ids = ordered.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        services.preferences.update { $0.moduleOrder = ids }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isPreview else { return }
        syncStarted()
        observeEnablement()
        observeActivity()
    }

    private func syncStarted() {
        for module in modules {
            let shouldRun = isEnabled(module)
            if shouldRun, !started.contains(module.id) {
                started.insert(module.id)
                module.start()
                Log.modules.info("Started module \(module.id, privacy: .public)")
            } else if !shouldRun, started.contains(module.id) {
                started.remove(module.id)
                module.stop()
                dismissAlerts(moduleID: module.id, coalescingKey: nil)
                Log.modules.info("Stopped module \(module.id, privacy: .public)")
            }
        }
    }

    private func observeEnablement() {
        withObservationTracking {
            _ = preferences.moduleEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.syncStarted()
                self?.observeEnablement()
            }
        }
    }

    /// Push "is anything live?" to every island whenever it changes.
    private func observeActivity() {
        withObservationTracking {
            _ = hasLiveActivity
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.syncIslands()
                self?.observeActivity()
            }
        }
    }

    /// Bring every island (including newly created ones) in line with the current state.
    func syncIslands() {
        let live = hasLiveActivity
        for island in services.islands {
            island.setLiveActivity(live)
            if currentAlert != nil, !island.machine.alertPending { island.beginAlert() }
        }
        services.screenManager.updateSuppression()
    }

    // MARK: - Alerts

    func present(_ alert: IslandAlert) {
        if let key = alert.coalescingKey {
            queue.removeAll { $0.moduleID == alert.moduleID && $0.coalescingKey == key }
            if let current = currentAlert, current.moduleID == alert.moduleID, current.coalescingKey == key {
                show(alert)
                return
            }
        }
        if currentAlert == nil { show(alert) } else { queue.append(alert) }
    }

    private func show(_ alert: IslandAlert) {
        alertWork?.cancel()
        withAnimation(services.themeStore.animation) { currentAlert = alert }
        FeedbackPlayer.play(alert.feedback, theme: services.themeStore.theme)
        for island in services.islands { island.beginAlert() }
        guard !alert.sticky else { return }
        let work = DispatchWorkItem { [weak self] in self?.finishCurrentAlert() }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (alert.duration ?? services.themeStore.theme.motion.alertDuration), execute: work)
    }

    func finishCurrentAlert() {
        alertWork?.cancel()
        alertWork = nil
        if queue.isEmpty {
            for island in services.islands { island.endAlert() }
            withAnimation(services.themeStore.animation) { currentAlert = nil }
        } else {
            show(queue.removeFirst())
        }
    }

    func dismissAlerts(moduleID: String, coalescingKey: String?) {
        queue.removeAll { $0.moduleID == moduleID && (coalescingKey == nil || $0.coalescingKey == coalescingKey) }
        if let current = currentAlert, current.moduleID == moduleID, coalescingKey == nil || current.coalescingKey == coalescingKey {
            finishCurrentAlert()
        }
    }

    /// Preview only: freeze an alert on screen.
    func setPreviewAlert(_ alert: IslandAlert?) {
        guard isPreview else { return }
        currentAlert = alert
    }
}

/// Plays the theme's sound and haptic for an event.
@MainActor
enum FeedbackPlayer {
    static func play(_ event: FeedbackEvent?, theme: Theme) {
        guard let event else { return }
        let sound = theme.feedback.sound(for: event)
        if sound.enabled { NSSound(named: NSSound.Name(sound.sound))?.play() }
        if theme.feedback.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}

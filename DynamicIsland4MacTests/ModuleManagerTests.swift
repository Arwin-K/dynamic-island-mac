import Observation
import SwiftUI
import Testing
@testable import DynamicIsland4Mac

@MainActor
@Observable
private final class FakeModule: IslandModule {
    let id: String
    let displayName: String
    let priority: Int
    let enabledByDefault: Bool
    var isActive = false
    var started = 0
    var stopped = 0

    init(id: String, priority: Int, enabledByDefault: Bool = true) {
        self.id = id
        self.displayName = id
        self.priority = priority
        self.enabledByDefault = enabledByDefault
    }

    func compactLeading() -> some View { Text(id) }
    func compactTrailing() -> some View { EmptyView() }
    func expanded() -> some View { Text(id) }
    func start() { started += 1 }
    func stop() { stopped += 1 }
}

@MainActor
struct ModuleManagerTests {
    /// Held by the test so it outlives the manager (which references it `unowned`).
    let services = AppServices(preferences: PreferencesStore(fileURL: nil), themeStore: ThemeStore())

    private func make(_ modules: [FakeModule]) -> (ModuleManager, AppServices) {
        (ModuleManager(services: services, modules: modules.map(AnyIslandModule.init)), services)
    }

    @Test func defaultOrderFollowsPriority() {
        let (m, _) = make([FakeModule(id: "b", priority: 20), FakeModule(id: "a", priority: 10)])
        #expect(m.ordered.map(\.id) == ["a", "b"])
    }

    @Test func userOrderWins() {
        let (m, services) = make([FakeModule(id: "a", priority: 10), FakeModule(id: "b", priority: 20), FakeModule(id: "c", priority: 30)])
        services.preferences.update { $0.moduleOrder = ["c", "a"] }
        #expect(m.ordered.map(\.id) == ["c", "a", "b"])
        m.move(from: IndexSet(integer: 2), to: 0)
        #expect(m.ordered.map(\.id) == ["b", "c", "a"])
    }

    @Test func optInModulesStartDisabled() {
        let (m, services) = make([FakeModule(id: "hud", priority: 10, enabledByDefault: false)])
        #expect(m.enabled.isEmpty)
        services.preferences.update { $0.moduleEnabled["hud"] = true }
        #expect(m.enabled.map(\.id) == ["hud"])
    }

    @Test func compactGoesToHighestPriorityActiveModule() {
        let music = FakeModule(id: "music", priority: 10)
        let agents = FakeModule(id: "agents", priority: 5)
        let (m, _) = make([music, agents])
        #expect(m.compactModule == nil)
        music.isActive = true
        #expect(m.compactModule?.id == "music")
        agents.isActive = true
        #expect(m.compactModule?.id == "agents")
        m.cycleCompact(by: 1)
        #expect(m.compactModule?.id == "music")
        m.cycleCompact(by: 1)
        #expect(m.compactModule?.id == "agents")
        // A selected module that goes idle falls back to the top active one.
        m.select("music")
        music.isActive = false
        #expect(m.compactModule?.id == "agents")
    }

    @Test func disabledModulesNeverShow() {
        let music = FakeModule(id: "music", priority: 10)
        music.isActive = true
        let (m, services) = make([music])
        services.preferences.update { $0.moduleEnabled["music"] = false }
        #expect(m.compactModule == nil)
        #expect(m.expandedTabs.isEmpty)
    }

    @Test func alertsQueueAndCoalesce() {
        let (m, _) = make([FakeModule(id: "x", priority: 1)])
        m.present(IslandAlert(moduleID: "x", content: AnyView(EmptyView()), sticky: true, coalescingKey: "s1"))
        let first = m.currentAlert?.id
        m.present(IslandAlert(moduleID: "x", content: AnyView(EmptyView()), sticky: true, coalescingKey: "s2"))
        #expect(m.currentAlert?.id == first)
        // Same key replaces the showing alert instead of queueing.
        m.present(IslandAlert(moduleID: "x", content: AnyView(EmptyView()), sticky: true, coalescingKey: "s1"))
        #expect(m.currentAlert?.id != first)
        #expect(m.currentAlert?.coalescingKey == "s1")
        m.finishCurrentAlert()
        #expect(m.currentAlert?.coalescingKey == "s2")
        m.dismissAlerts(moduleID: "x", coalescingKey: "s2")
        #expect(m.currentAlert == nil)
    }
}

import SwiftUI

/// **The one place modules are registered.** To add a module, write it (see
/// `Battery/BatteryModule.swift` for a small complete example) and add one line below.
/// The order here doesn't matter; each module's `priority` sets its default position and
/// users reorder in Settings → Modules.
@MainActor
enum ModuleRegistry {
    static func makeModules(services: AppServices) -> [AnyIslandModule] {
        let r = Registrar(services: services, isPreview: false)
        r.add { AgentsModule(context: $0, store: services.agentHub.store, providers: services.agentHub.providers, approvals: services.agentHub.approvals) }
        r.add { NowPlayingModule(context: $0) }
        r.add { BatteryModule(context: $0) }
        r.add { CalendarModule(context: $0) }
        r.add { HUDModule(context: $0) }
        r.add { ShelfModule(context: $0) }
        r.add { FocusTimerModule(context: $0) }
        return r.modules
    }

    /// Modules filled with fake data for the live preview in Settings → Appearance, so
    /// themes can be designed without music playing or agents running. Optional per module.
    static func makePreviewModules(services: AppServices) -> [AnyIslandModule] {
        let r = Registrar(services: services, isPreview: true)
        r.add { AgentsModule.preview(context: $0) }
        r.add { NowPlayingModule.preview(context: $0) }
        r.add { BatteryModule.preview(context: $0) }
        r.add { CalendarModule.preview(context: $0) }
        r.add { ShelfModule.preview(context: $0) }
        return r.modules
    }

    /// The alert shown in the preview's "Alert" tile.
    static func makePreviewAlert(services: AppServices, modules: [AnyIslandModule]) -> IslandAlert {
        if let agents = modules.first(where: { $0.id == "agents" })?.base as? AgentsModule {
            return IslandAlert(moduleID: "agents", content: AnyView(AgentAlertView(module: agents, sessionID: "claude-code:preview-1", transition: .needsPermission(detail: "Bash: npm run build"))))
        }
        return IslandAlert(moduleID: "battery", content: AnyView(BatteryAlertView(level: 0.64, kind: .charging)))
    }

    /// Creates each module with its own `ModuleContext`.
    @MainActor
    final class Registrar {
        let services: AppServices
        let isPreview: Bool
        private(set) var modules: [AnyIslandModule] = []

        init(services: AppServices, isPreview: Bool) {
            self.services = services
            self.isPreview = isPreview
        }

        func add<M: IslandModule>(_ make: (ModuleContext) -> M) {
            let context = ModuleContext(moduleID: "", services: services, isPreview: isPreview)
            let module = make(context)
            context.moduleID = module.id
            modules.append(AnyIslandModule(module))
        }
    }
}

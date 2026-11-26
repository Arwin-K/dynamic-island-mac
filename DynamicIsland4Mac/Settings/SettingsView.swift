import Observation
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, behavior, modules, agents, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .behavior: "Behavior"
        case .modules: "Modules"
        case .agents: "Agents"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .behavior: "cursorarrow.motionlines"
        case .modules: "square.grid.2x2"
        case .agents: "sparkles"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPane = .appearance
}

struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let services: AppServices

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { navigation.selection },
                set: { if let new = $0 { navigation.selection = new } }
            )) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .appearance: AppearanceSettingsView(services: services)
        case .behavior: BehaviorSettingsView(services: services)
        case .modules: ModulesSettingsView(services: services)
        case .agents: AgentsSettingsView(services: services)
        case .permissions: PermissionsSettingsView(services: services)
        case .about: AboutSettingsView()
        }
    }
}

import SwiftUI

/// Settings → Modules: turn modules on and off, drag to set priority, and each module's own settings.
struct ModulesSettingsView: View {
    let services: AppServices
    @State private var expanded: Set<String> = []

    private var manager: ModuleManager { services.moduleManager }

    var body: some View {
        List {
            Section {
                ForEach(manager.ordered) { module in
                    ModuleRow(module: module, manager: manager, isExpanded: Binding(
                        get: { expanded.contains(module.id) },
                        set: { if $0 { expanded.insert(module.id) } else { expanded.remove(module.id) } }
                    ))
                }
                .onMove { manager.move(from: $0, to: $1) }
            } header: {
                Text("Drag to set priority. When several modules have a live activity, the highest one gets the compact island; swipe sideways on the island to see the others.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
        }
        .listStyle(.inset)
    }
}

private struct ModuleRow: View {
    let module: AnyIslandModule
    let manager: ModuleManager
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                module.settingsView()
            }
            .padding(.vertical, 6)
            .disabled(!manager.isEnabled(module))
        } label: {
            HStack {
                Image(systemName: module.symbolName)
                    .frame(width: 22)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.displayName)
                    if manager.isEnabled(module) && module.isActive {
                        Text("Live now").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { manager.isEnabled(module) },
                    set: { manager.setEnabled(module.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("\(module.displayName) enabled")
            }
        }
    }
}

import Observation
import SwiftUI

/// Volume and brightness overlays in the island instead of the system's. Opt-in, because it
/// needs Accessibility permission (see `HUDService`).
@MainActor
@Observable
final class HUDModule: IslandModule {
    let id = "hud"
    let displayName = "Volume & Brightness"
    let symbolName = "speaker.wave.2"
    let priority = 60
    let enabledByDefault = false
    let isActive = false

    @ObservationIgnored let context: ModuleContext
    @ObservationIgnored let service = HUDService()
    private(set) var isTrusted = HUDService.isTrusted
    private(set) var isRunning = false
    @ObservationIgnored private var trustObserver: NSObjectProtocol?
    @ObservationIgnored private var wantsRunning = false

    init(context: ModuleContext) {
        self.context = context
    }

    func start() {
        wantsRunning = true
        service.handleVolume = context.bool("volume", default: true)
        service.handleBrightness = context.bool("brightness", default: true)
        service.onChange = { [weak self] change in self?.show(change) }
        // Posted when any app's Accessibility trust changes, so we notice the grant without polling.
        trustObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.retry() }
            }
        }
        retry()
    }

    func stop() {
        wantsRunning = false
        service.stop()
        isRunning = false
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
    }

    func retry() {
        isTrusted = HUDService.isTrusted
        guard wantsRunning, isTrusted else { return }
        isRunning = service.start()
    }

    func applySettings() {
        service.handleVolume = context.bool("volume", default: true)
        service.handleBrightness = context.bool("brightness", default: true)
    }

    private func show(_ change: HUDService.Change) {
        context.alert(feedback: nil, duration: 1.4, coalescingKey: "hud") {
            HUDAlertView(change: change)
        }
    }

    func compactLeading() -> some View { EmptyView() }
    func compactTrailing() -> some View { EmptyView() }
    func expanded() -> some View { EmptyView() }

    func settingsView() -> AnyView {
        AnyView(HUDSettingsView(module: self))
    }
}

struct HUDAlertView: View {
    let change: HUDService.Change
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var symbol: String {
        switch change.kind {
        case .brightness: return change.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if change.muted || change.level == 0 { return "speaker.slash.fill" }
            return change.level < 0.34 ? "speaker.wave.1.fill" : (change.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: theme.icons.weight.weight))
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.foreground.opacity(0.18))
                    Capsule().fill(palette.foreground)
                        .frame(width: geo.size.width * (change.muted ? 0 : change.level))
                }
            }
            .frame(height: 6)
            Text("\(Int((change.muted ? 0 : change.level) * 100))")
                .font(theme.timerFont)
                .foregroundStyle(palette.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(change.kind == .volume ? (change.muted ? "Muted" : "Volume \(Int(change.level * 100)) percent") : "Brightness \(Int(change.level * 100)) percent")
    }
}

struct HUDSettingsView: View {
    let module: HUDModule

    var body: some View {
        if module.isTrusted {
            Label(module.isRunning ? "Active: volume and brightness keys show in the island." : "Permission granted.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Needs Accessibility permission to intercept the volume and brightness keys.", systemImage: "lock")
                    .foregroundStyle(.orange)
                Text("1. Click Grant Access. 2. In System Settings → Privacy & Security → Accessibility, turn on DynamicIsland4Mac. The module starts by itself as soon as access is granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Grant Access…") { HUDService.requestTrust() }
                    Button("Open Accessibility Settings") { HUDService.openAccessibilitySettings() }
                }
            }
        }
        Toggle("Volume keys", isOn: Binding(get: { module.context.bool("volume", default: true) },
                                            set: { module.context.set("volume", $0); module.applySettings() }))
        Toggle("Brightness keys", isOn: Binding(get: { module.context.bool("brightness", default: true) },
                                                set: { module.context.set("brightness", $0); module.applySettings() }))
        if !DisplayBrightness.isAvailable {
            Text("Brightness control isn't available on this macOS version; the brightness keys keep the system overlay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Hold ⌥⇧ for finer steps. ⌥ + key still opens the system settings for that key.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

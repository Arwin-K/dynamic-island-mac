import Observation
import SwiftUI

/// Battery and charging. The smallest real module, and a good template for your own:
///
/// 1. An `@Observable` class conforming to `IslandModule`, created with a `ModuleContext`.
/// 2. `start()` subscribes to a service; `stop()` unsubscribes.
/// 3. `isActive` decides when it wants the compact slot (here: a few seconds after plugging in,
///    or while the battery is low).
/// 4. Alerts go through `context.alert { … }`; settings through `context.bool(…)`.
@MainActor
@Observable
final class BatteryModule: IslandModule {
    let id = "battery"
    let displayName = "Battery"
    let symbolName = "battery.75percent"
    let priority = 50
    var showsInExpandedWhenIdle: Bool { service.snapshot.hasBattery }

    let service: BatteryService
    @ObservationIgnored let context: ModuleContext
    /// True for a few seconds after the charger is connected.
    private var showingChargeFlash = false
    @ObservationIgnored private var flashWork: DispatchWorkItem?
    @ObservationIgnored private var lastLowAlertLevel: Int?

    init(context: ModuleContext, service: BatteryService? = nil) {
        self.context = context
        self.service = service ?? BatteryService()
    }

    // Settings (stored by the context; no persistence code needed here).
    private var alwaysShow: Bool { context.bool("alwaysShow", default: false) }
    private var chargeAnimation: Bool { context.bool("chargeAnimation", default: true) }
    private var lowThreshold: Double { context.double("lowThreshold", default: 20) }

    var snapshot: BatteryService.Snapshot { service.snapshot }
    var isLow: Bool { snapshot.hasBattery && !snapshot.isPluggedIn && snapshot.level * 100 <= lowThreshold }

    var isActive: Bool {
        guard snapshot.hasBattery else { return false }
        return alwaysShow || showingChargeFlash || isLow
    }

    func start() {
        service.onChange = { [weak self] old, new in self?.handle(old: old, new: new) }
        service.start()
    }

    func stop() {
        service.stop()
        service.onChange = nil
        flashWork?.cancel()
        showingChargeFlash = false
    }

    private func handle(old: BatteryService.Snapshot, new: BatteryService.Snapshot) {
        guard new.hasBattery else { return }
        // Charger connected.
        if new.isPluggedIn && !old.isPluggedIn && old.hasBattery {
            if chargeAnimation {
                context.alert(feedback: .batteryCharging, coalescingKey: "power") {
                    BatteryAlertView(level: new.level, kind: .charging)
                }
            }
            showingChargeFlash = true
            flashWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showingChargeFlash = false }
            flashWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
        if new.isPluggedIn { lastLowAlertLevel = nil }

        // Low battery: alert once at the threshold and again at half of it.
        let percent = Int((new.level * 100).rounded())
        let thresholds = [Int(lowThreshold), Int(lowThreshold / 2)].filter { $0 > 0 }
        if !new.isPluggedIn, let hit = thresholds.first(where: { percent <= $0 }),
           lastLowAlertLevel.map({ hit < $0 }) ?? true {
            lastLowAlertLevel = hit
            context.alert(feedback: .batteryLow, coalescingKey: "low") {
                BatteryAlertView(level: new.level, kind: .low)
            }
        }
    }

    // MARK: Views

    func compactLeading() -> some View {
        BatteryGlyph(level: snapshot.level, charging: snapshot.isCharging || snapshot.isPluggedIn, low: isLow)
            .frame(width: 26, height: 13)
            .islandMatched("glyph", module: id)
            .accessibilityHidden(true)
    }

    func compactTrailing() -> some View {
        BatteryPercentText(level: snapshot.level, low: isLow)
            .accessibilityLabel("Battery \(Int(snapshot.level * 100)) percent\(snapshot.isCharging ? ", charging" : "")")
    }

    func expanded() -> some View {
        BatteryExpandedView(service: service, isLow: isLow, moduleID: id)
    }

    func settingsView() -> AnyView {
        AnyView(BatterySettingsView(context: context))
    }

    /// Fake data for the Settings preview.
    static func preview(context: ModuleContext) -> BatteryModule {
        let module = BatteryModule(context: context)
        module.service.setPreview(
            BatteryService.Snapshot(hasBattery: true, level: 0.64, isCharging: true, isPluggedIn: true, minutesToFull: 48),
            details: BatteryService.Details(cycleCount: 212, healthPercent: 94, batteryWatts: 38.5, adapterWatts: 96))
        module.showingChargeFlash = true
        return module
    }
}

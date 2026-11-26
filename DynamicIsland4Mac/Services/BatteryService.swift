import Foundation
import IOKit.ps
import Observation

/// Battery state from IOKit power-source notifications. No polling: IOKit calls us when
/// anything about the power source changes (level, charger, charging state).
@MainActor
@Observable
final class BatteryService {
    struct Snapshot: Equatable {
        var hasBattery = false
        /// 0...1
        var level: Double = 1
        var isCharging = false
        var isPluggedIn = false
        var isCharged = false
        /// Minutes; nil while macOS is still estimating.
        var minutesToEmpty: Int?
        var minutesToFull: Int?
        var lowPowerMode = false
    }

    private(set) var snapshot = Snapshot()
    /// Called on the main actor with (old, new) after every change.
    @ObservationIgnored var onChange: ((Snapshot, Snapshot) -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var powerStateObserver: NSObjectProtocol?

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        powerStateObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
        if let observer = powerStateObserver { NotificationCenter.default.removeObserver(observer) }
        powerStateObserver = nil
    }

    func refresh() {
        let new = Self.read()
        let old = snapshot
        guard new != old else { return }
        snapshot = new
        onChange?(old, new)
    }

    /// Settings preview only: show fake data.
    func setPreview(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    nonisolated static func read() -> Snapshot {
        var s = Snapshot()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return s }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery"
            else { continue }
            s.hasBattery = true
            let current = desc["Current Capacity"] as? Double ?? 100
            let max = desc["Max Capacity"] as? Double ?? 100
            s.level = max > 0 ? min(current / max, 1) : 1
            s.isCharging = desc["Is Charging"] as? Bool ?? false
            s.isPluggedIn = (desc["Power Source State"] as? String) == "AC Power"
            s.isCharged = desc["Is Charged"] as? Bool ?? false
            if let m = desc["Time to Empty"] as? Int, m > 0 { s.minutesToEmpty = m }
            if let m = desc["Time to Full Charge"] as? Int, m > 0 { s.minutesToFull = m }
        }
        return s
    }
}

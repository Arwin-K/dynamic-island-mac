import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// Intercepts the volume and brightness keys so the island can show its own overlay
/// instead of the system's.
///
/// How: a `CGEventTap` on `NX_SYSDEFINED` events (where the media keys arrive). When we can
/// change the value ourselves, we swallow the key (so the system overlay doesn't appear),
/// apply the change, and report it. When we can't (no permission, an audio device without a
/// software volume, DisplayServices missing), the key passes through untouched and macOS
/// behaves as usual.
///
/// An event tap that can *modify* events needs Accessibility permission. That's why the HUD
/// module is opt-in and does nothing until the user grants it.
@MainActor
final class HUDService {
    enum Kind: Equatable { case volume, brightness }

    struct Change: Equatable {
        var kind: Kind
        var level: Double
        var muted: Bool
    }

    var onChange: ((Change) -> Void)?
    var handleVolume = true
    var handleBrightness = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and adds the app to the Accessibility list.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns false when Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<HUDService>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { service.handle(type: type, event: event) }
        }, userInfo: info) else {
            Log.hud.error("Could not create the event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.hud.info("HUD event tap started")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that are slow or when the user is typing a password; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = Int((ns.data1 & 0xFFFF_0000) >> 16)
        let keyDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        // ⌥ + key opens the related System Settings pane: leave that to macOS.
        let mods = ns.modifierFlags.intersection([.option, .shift, .command, .control])
        if mods == .option { return Unmanaged.passUnretained(event) }
        let fine = mods == [.option, .shift]
        let step = fine ? 1.0 / 64 : 1.0 / 16

        switch keyCode {
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP, SOUND_DOWN, MUTE
            guard handleVolume, let volume = SystemVolume.current() else { return Unmanaged.passUnretained(event) }
            if keyDown {
                var level = volume.level
                var muted = volume.muted
                if keyCode == 7 {
                    muted.toggle()
                } else {
                    level = min(1, max(0, level + (keyCode == 0 ? step : -step)))
                    muted = level == 0
                }
                guard SystemVolume.set(level: level, muted: muted) else { return Unmanaged.passUnretained(event) }
                onChange?(Change(kind: .volume, level: level, muted: muted))
            }
            return nil
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP, BRIGHTNESS_DOWN
            guard handleBrightness, let current = DisplayBrightness.current() else { return Unmanaged.passUnretained(event) }
            if keyDown {
                let level = min(1, max(0, current + (keyCode == 2 ? step : -step)))
                guard DisplayBrightness.set(level) else { return Unmanaged.passUnretained(event) }
                onChange?(Change(kind: .brightness, level: level, muted: false))
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// The default output device's volume through public CoreAudio.
enum SystemVolume {
    private static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func current() -> (level: Double, muted: Bool)? {
        guard let device = defaultDevice() else { return nil }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        var mute = UInt32(0)
        var muteAddr = muteAddress
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &mute)
        return (Double(volume), mute != 0)
    }

    static func set(level: Double, muted: Bool) -> Bool {
        guard let device = defaultDevice() else { return false }
        var address = volumeAddress
        var volume = Float32(level)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        var muteAddr = muteAddress
        if AudioObjectHasProperty(device, &muteAddr) {
            var mute = UInt32(muted ? 1 : 0)
            _ = AudioObjectSetPropertyData(device, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
        return status == noErr
    }
}

/// Built-in display brightness through the private DisplayServices framework, loaded at
/// runtime so a missing or changed framework just means "not supported" (the key then passes
/// through to macOS) rather than a crash or a launch failure.
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (get: GetFn, set: SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            Log.hud.error("DisplayServices unavailable; brightness keys stay with macOS")
            return nil
        }
        return (unsafeBitCast(get, to: GetFn.self), unsafeBitCast(set, to: SetFn.self))
    }()

    static var isAvailable: Bool { functions != nil }

    private static var display: CGDirectDisplayID {
        NSScreen.screens.first(where: \.isBuiltIn)?.displayID ?? CGMainDisplayID()
    }

    static func current() -> Double? {
        guard let functions else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0 else { return nil }
        return Double(value)
    }

    static func set(_ level: Double) -> Bool {
        guard let functions else { return false }
        return functions.set(display, Float(level)) == 0
    }
}

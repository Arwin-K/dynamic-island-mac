import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// The system output volume, kept in sync with CoreAudio property listeners (no polling):
/// volume and mute changes on the current device, and switches of the default output
/// device (plugging in headphones, AirPods connecting).
@MainActor
@Observable
final class VolumeController {
    static let shared = VolumeController()

    private(set) var level: Double = 0
    private(set) var muted = false
    /// False when the current output device has no software volume (some HDMI/USB devices).
    private(set) var isAvailable = false

    @ObservationIgnored private var device: AudioDeviceID = kAudioObjectUnknown
    @ObservationIgnored private var started = false
    @ObservationIgnored private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.attachToDefaultDevice() }
    }
    @ObservationIgnored private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.refresh() }
    }

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// Starts listening (idempotent). Cheap: the listeners only fire on actual changes.
    func start() {
        guard !started else { return }
        started = true
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, nil, deviceListener)
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, nil, valueListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, nil, valueListener)
        }
        var newDevice = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &newDevice)
        device = status == noErr ? newDevice : kAudioObjectUnknown
        if device != kAudioObjectUnknown {
            AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, nil, valueListener)
            AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, nil, valueListener)
        }
        refresh()
    }

    func refresh() {
        if let current = SystemVolume.current() {
            isAvailable = true
            level = current.level
            muted = current.muted
        } else {
            isAvailable = false
        }
    }

    /// Sets the volume (0...1). Moving the slider up from zero unmutes.
    func set(_ newLevel: Double) {
        let clamped = min(max(newLevel, 0), 1)
        let mute = clamped == 0
        level = clamped
        muted = mute
        _ = SystemVolume.set(level: clamped, muted: mute)
    }

    func toggleMute() {
        muted.toggle()
        _ = SystemVolume.set(level: level, muted: muted)
    }
}

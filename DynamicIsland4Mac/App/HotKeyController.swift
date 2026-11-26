import AppKit
import Carbon.HIToolbox
import Observation

/// The global "toggle the island" shortcut.
///
/// Uses Carbon's `RegisterEventHotKey`, which is still the only public API for a system-wide
/// hotkey that needs **no** Accessibility or Input Monitoring permission (an `NSEvent` global
/// key monitor would need both and sees every keystroke).
@MainActor
final class HotKeyController {
    private unowned let services: AppServices
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: KeyboardShortcutSpec?

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        installHandler()
        apply()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = services.preferences.values.toggleShortcut
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.apply()
                self?.observe()
            }
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppServices.shared.screenManager.primaryIsland?.toggle()
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    private func apply() {
        let spec = services.preferences.values.toggleShortcut
        guard spec != registered else { return }
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        registered = spec
        guard spec.enabled else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_344D), id: 1) // "DI4M"
        let status = RegisterEventHotKey(spec.keyCode, Self.carbonModifiers(spec.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.app.error("Could not register shortcut (status \(status)). Another app may be using it.")
        }
    }

    static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// A readable form like "⌃⌥I" for Settings.
    static func describe(_ spec: KeyboardShortcutSpec) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: spec.modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName(spec.keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫", UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        ]
        if let name = special[keyCode] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

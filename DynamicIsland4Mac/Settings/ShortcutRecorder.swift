import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a key combination. Needs at least one of ⌘ ⌥ ⌃. Esc cancels.
/// Uses a *local* key monitor, which only sees keys while the Settings window is focused,
/// so no permission is required.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyboardShortcutSpec
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : (shortcut.enabled ? HotKeyController.describe(shortcut) : "None"))
                    .frame(minWidth: 90)
            }
            .accessibilityLabel(isRecording ? "Recording shortcut. Press keys." : "Shortcut \(HotKeyController.describe(shortcut)). Click to change.")
            if shortcut.enabled {
                Button {
                    shortcut.enabled = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            shortcut = KeyboardShortcutSpec(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, enabled: true)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

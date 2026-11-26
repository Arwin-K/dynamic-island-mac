import AppKit
import SwiftUI

/// The borderless, non-activating panel that hosts one island.
///
/// Why each setting:
/// * `.nonactivatingPanel` + `canBecomeKey == false`: clicking the island must never steal
///   keyboard focus from the app you're typing in (your terminal running Claude Code, say).
/// * `level = .mainMenu + 3`: the island has to draw *over* the menu bar (it sits in the
///   menu bar's band, around the notch). `.mainMenu + 1/+2` are used by the menu bar itself
///   and its status item windows, so +3 is the lowest level that reliably stays on top of
///   them without fighting system UI like the screen-saver or alert levels.
/// * `.canJoinAllSpaces` + `.stationary`: one island for every Space; it doesn't slide
///   during Space switches or Mission Control.
/// * `.fullScreenAuxiliary`: allowed to appear next to full-screen apps (we hide it
///   ourselves when the user wants that, see `ScreenManager`).
/// * `.ignoresCycle`: never shows up in ⌘` window cycling.
/// * Clear background, `hasShadow = false`: the window itself is invisible; the island shape
///   and its shadow are drawn in SwiftUI so they follow the animated outline.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // `ignoresMouseEvents` is deliberately left at its default. See `IslandWindowController`
        // for the click-through strategy.
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes windows below the menu bar. The island lives *in* the menu bar
    /// band, so take the frame exactly as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that accepts the first click even though our app is never active.
/// Without this, the first click on the island would only "activate" the window and
/// buttons would need a second click.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Called with +1 / -1 for a horizontal two-finger swipe (used to cycle activities).
    var onHorizontalSwipe: ((Int) -> Void)?
    private var swipeAccumulator: CGFloat = 0
    private var swipeFired = false

    override func scrollWheel(with event: NSEvent) {
        // Only clearly horizontal gestures; vertical scrolling goes to SwiftUI (lists).
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.hasPreciseScrollingDeltas {
            if event.phase == .began { swipeAccumulator = 0; swipeFired = false }
            swipeAccumulator += event.scrollingDeltaX
            if !swipeFired, abs(swipeAccumulator) > 40 {
                swipeFired = true
                onHorizontalSwipe?(swipeAccumulator < 0 ? 1 : -1)
            }
            if event.phase == .ended || event.phase == .cancelled { swipeAccumulator = 0; swipeFired = false }
            return
        }
        super.scrollWheel(with: event)
    }
}

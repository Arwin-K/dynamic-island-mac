import AppKit
import Observation
import SwiftUI

/// Owns one island panel on one display and keeps the panel's frame in sync with the
/// island's state.
///
/// ## Click-through strategy
///
/// The menu bar has items right next to the notch, so wherever the island isn't drawn,
/// clicks must reach the menu bar. There are two classic approaches:
///
/// 1. Keep a big fixed window and toggle `ignoresMouseEvents` from a global mouse-moved
///    monitor. That needs an always-on global event monitor (CPU on every mouse move, all
///    day) and has a visible lag at the edges.
/// 2. **Resize the panel to the island's current bounding box** (what we do). Outside that
///    box there is simply no window, so the menu bar gets the click with zero overhead.
///
/// Inside the box, the rounded corners and the shadow margin are fully transparent pixels.
/// Because `ignoresMouseEvents` is left at its *default* (not explicitly set to `false`),
/// the window server ignores clicks on fully transparent pixels of a non-opaque window and
/// passes them through, so even the corner gaps are click-through.
///
/// Resizing a window in sync with a SwiftUI spring is impossible to do perfectly, so:
/// growing happens immediately (the panel becomes the union of old and new frames, then the
/// shape springs out inside it), and shrinking waits until the spring has settled. The
/// island is pinned to the panel's top center, so resizing never moves the drawn content.
@MainActor
final class IslandWindowController {
    let panel: IslandPanel
    let model: IslandViewModel
    private(set) var screen: NSScreen

    private var shrinkWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?

    init(screen: NSScreen, services: AppServices) {
        self.screen = screen
        let geometry = NotchGeometry.forScreen(screen, pillSize: Self.pillSize(services.themeStore.theme))
        model = IslandViewModel(services: services, geometry: geometry, modules: services.moduleManager)
        panel = IslandPanel(contentRect: model.layout.frame)

        let hosting = IslandHostingView(rootView: IslandRootView(model: model))
        hosting.onHorizontalSwipe = { [weak model] step in model?.swiped(step) }
        // The controller owns the window frame, not SwiftUI. A hosting view that *is* the
        // window's contentView animates the window size itself during `withAnimation`
        // (`updateAnimatedWindowSize`), which fights our resizing and can end in an
        // "Update Constraints in Window" exception. Embedding it in a plain container view
        // and turning off its sizing options keeps SwiftUI out of window management.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: model.layout.frame.size))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        panel.sharingType = Self.sharingType(services.preferences.values)

        apply(model.layout, animated: false)
        panel.orderFrontRegardless()
        observeLayout()
        observeOpenState()
    }

    /// Excluded from captures per the preference. Debug builds accept `-DI4MAllowCapture YES`
    /// to override it for screenshots without changing the user's preferences.
    static func sharingType(_ prefs: Preferences) -> NSWindow.SharingType {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DI4MAllowCapture") { return .readOnly }
        #endif
        return prefs.hideFromScreenCapture ? .none : .readOnly
    }

    static func pillSize(_ theme: Theme) -> CGSize {
        CGSize(width: theme.geometry.pillWidth, height: theme.geometry.pillHeight)
    }

    /// Called when screens change (resolution, arrangement, lid) or the pill size changes.
    func update(screen: NSScreen) {
        self.screen = screen
        let geometry = NotchGeometry.forScreen(screen, pillSize: Self.pillSize(model.services.themeStore.theme))
        if geometry != model.geometry { model.geometry = geometry }
        panel.sharingType = Self.sharingType(model.services.preferences.values)
    }

    func close() {
        shrinkWork?.cancel()
        removeOutsideClickMonitor()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Layout

    private func observeLayout() {
        withObservationTracking {
            _ = model.layout
        } onChange: { [weak self] in
            // onChange fires *before* the change is applied; hop to the next main-loop turn.
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(self.model.layout, animated: true)
                self.observeLayout()
            }
        }
    }

    private func apply(_ layout: PanelLayout, animated: Bool) {
        shrinkWork?.cancel()
        panel.setSuppressed(layout.isSuppressed)
        let target = layout.frame
        let current = panel.frame
        Log.window.debug("Panel layout \(NSStringFromRect(current), privacy: .public) → \(NSStringFromRect(target), privacy: .public) suppressed=\(layout.isSuppressed)")
        guard target != current else { return }

        if !animated || current.isEmpty {
            panel.setFrame(target, display: true)
            return
        }
        // Grow now (to the union, so nothing is clipped mid-animation)…
        let union = current.union(target)
        if union != current { panel.setFrame(union, display: true) }
        // …and shrink once the spring has settled.
        if union != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.panel.setFrame(self.model.layout.frame, display: true)
            }
            shrinkWork = work
            let delay = model.services.themeStore.settleDuration + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - Close on outside click

    /// While the island is open, a click anywhere else closes it. The global monitor only
    /// exists while open, so there's no cost when collapsed. Mouse-down monitors don't need
    /// Accessibility permission.
    private func observeOpenState() {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.model.state == .expanded { self.installOutsideClickMonitor() } else { self.removeOutsideClickMonitor() }
                self.observeOpenState()
            }
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.clickedOutside() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }
}

private extension NSPanel {
    /// A hidden island must not swallow clicks either, so it is ordered out entirely rather
    /// than toggling `ignoresMouseEvents` (explicitly setting that to `false` later would
    /// turn off the transparent-pixel click-through described above).
    func setSuppressed(_ suppressed: Bool) {
        if suppressed {
            if isVisible { orderOut(nil) }
        } else if !isVisible {
            orderFrontRegardless()
        }
    }
}

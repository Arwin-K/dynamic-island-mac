import AppKit
import Observation
import SwiftUI

/// One island on one display: its state machine, its size in each state, and the input
/// handling (hover, click, shortcut, alerts). Views read from it; the window controller
/// sizes the panel from it.
@MainActor
@Observable
final class IslandViewModel {
    @ObservationIgnored unowned let services: AppServices
    /// Where the content comes from: the app's modules, or fake ones in the Settings preview.
    let modules: ModuleManager
    var geometry: NotchGeometry

    private(set) var machine = IslandStateMachine()
    var state: IslandState { machine.state }
    private(set) var isHovering = false
    /// Opened by click or shortcut: stays open when the pointer leaves, until clicked again,
    /// a click lands outside, or the shortcut is pressed again.
    private(set) var isPinnedOpen = false
    /// Set by the screen manager (full-screen apps, idle pill hiding).
    var isSuppressed = false

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// Preview islands (Settings → Appearance) are frozen in one state and ignore input.
    let isPreview: Bool

    init(services: AppServices, geometry: NotchGeometry, modules: ModuleManager, previewState: IslandState? = nil) {
        self.services = services
        self.modules = modules
        self.geometry = geometry
        self.isPreview = previewState != nil
        if let previewState {
            switch previewState {
            case .collapsed: break
            case .compact: machine.setLiveActivity(true)
            case .expanded: machine.open()
            case .alert: machine.beginAlert()
            }
        }
    }

    var theme: Theme { services.themeStore.theme }
    private var preferences: Preferences { services.preferences.values }

    // MARK: - Transitions

    private func transition(_ change: (inout IslandStateMachine) -> Void) {
        var next = machine
        change(&next)
        guard next != machine else { return }
        Log.window.debug("Island state \(self.machine.state.rawValue, privacy: .public) → \(next.state.rawValue, privacy: .public)")
        withAnimation(services.themeStore.animation) {
            machine = next
        }
    }

    func open(pinned: Bool = false) {
        isPinnedOpen = pinned
        transition { $0.open() }
    }

    func close() {
        isPinnedOpen = false
        transition { $0.close() }
    }

    func toggle() {
        machine.isOpen ? close() : open(pinned: true)
    }

    func setLiveActivity(_ active: Bool) {
        transition { $0.setLiveActivity(active) }
    }

    func beginAlert() { transition { $0.beginAlert() } }
    func endAlert() { transition { $0.endAlert() } }

    // MARK: - Input

    func hoverChanged(_ inside: Bool) {
        guard !isPreview else { return }
        isHovering = inside
        hoverTask?.cancel()
        let motion = theme.motion
        if inside {
            guard preferences.openMode.opensOnHover, !machine.isOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(motion.hoverDelay))
                guard let self, !Task.isCancelled, self.isHovering else { return }
                self.open()
            }
        } else {
            guard machine.isOpen, preferences.closeOnMouseExit, !isPinnedOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(motion.autoCollapseDelay))
                guard let self, !Task.isCancelled, !self.isHovering else { return }
                self.close()
            }
        }
    }

    func tapped() {
        guard !isPreview else { return }
        if machine.isOpen {
            if isPinnedOpen || !preferences.openMode.opensOnHover { close() }
            return
        }
        // Clicking an alert or compact activity always opens it on that module, whatever the open mode.
        if state == .alert, let alert = modules.currentAlert { modules.select(alert.moduleID) }
        if state == .compact, let module = modules.compactModule { modules.select(module.id) }
        if preferences.openMode.opensOnClick || state == .alert || state == .compact {
            open(pinned: !preferences.openMode.opensOnHover || preferences.openMode == .both)
        }
    }

    /// A horizontal two-finger swipe on the island: cycle compact activities.
    func swiped(_ step: Int) {
        guard !isPreview, state == .compact else { return }
        modules.cycleCompact(by: step)
    }

    /// A click somewhere else on screen while the island is open.
    func clickedOutside() {
        if machine.isOpen && !isHovering { close() }
    }

    // MARK: - Geometry

    /// Whether the island is drawn as a notch extension (flares at the top) or a floating
    /// rounded shape (pill displays, or a theme with a vertical offset).
    var isFloating: Bool { !geometry.hasNotch || theme.geometry.verticalOffset > 0.5 }

    var topCurve: CGFloat { isFloating ? 0 : CGFloat(theme.geometry.topCurveDepth) }

    /// Width of the hardware notch (the gap compact content must leave in the middle).
    /// The no-go zone in the middle of the island: the hardware notch plus a small clearance
    /// on each side, so no text or button ever sits under (or touches) the camera housing.
    var centerGap: CGFloat { geometry.hasNotch ? geometry.baseRect.width + Self.notchClearance * 2 : 10 }
    static let notchClearance: CGFloat = 6

    /// Width available on each side of the notch for content, given the island's horizontal
    /// inset (padding + top flare) in the current state.
    func sideContentWidth(for state: IslandState, inset: CGFloat) -> CGFloat {
        max(0, (islandSize(for: state).width - inset * 2 - centerGap) / 2)
    }

    func islandSize(for state: IslandState) -> CGSize {
        let g = theme.geometry
        let base = geometry.baseRect.size
        let flare = topCurve * 2
        let side = CGFloat(modules.compactModule?.preferredCompactSideWidth ?? g.compactSideWidth)
        let compactWidth: CGFloat = geometry.hasNotch
            ? base.width + side * 2 + flare
            : max(base.width, side * 2 + centerGap + 24)
        // On a notched display the resting island wraps around the hardware notch by a few
        // points, so it reads as a shape hugging the notch rather than disappearing into it.
        let hugsNotch = geometry.hasNotch && !isFloating
        let sideOutset = hugsNotch ? CGFloat(max(0, g.collapsedSideOutset)) : 0
        let bottomOutset = hugsNotch ? CGFloat(max(0, g.collapsedBottomOutset)) : 0
        switch state {
        case .collapsed:
            return CGSize(width: base.width + sideOutset * 2 + flare, height: base.height + bottomOutset)
        case .compact:
            return CGSize(width: max(compactWidth, base.width + sideOutset * 2 + flare), height: base.height + bottomOutset)
        case .alert:
            return CGSize(width: max(CGFloat(g.alertWidth), compactWidth), height: base.height + CGFloat(g.alertHeight))
        case .expanded:
            let height = max(g.expandedHeight, modules.expandedModule?.preferredExpandedHeight ?? 0)
            return CGSize(width: max(CGFloat(g.expandedWidth), compactWidth), height: base.height + CGFloat(height))
        }
    }

    var islandSize: CGSize { islandSize(for: state) }

    func bottomRadius(for state: IslandState) -> CGFloat {
        let g = theme.geometry
        let size = islandSize(for: state)
        let r: Double
        switch state {
        case .collapsed: r = isFloating ? Double(size.height) / 2 : g.collapsedBottomRadius
        case .compact: r = isFloating ? Double(size.height) / 2 : g.compactBottomRadius
        case .alert, .expanded: r = g.expandedBottomRadius
        }
        return CGFloat(min(r, Double(size.height) / 2))
    }

    var shape: NotchShape {
        let bottom = bottomRadius(for: state)
        return NotchShape(topCurve: topCurve, bottomRadius: bottom, topRadius: isFloating ? bottom : 0)
    }

    /// Transparent margin around the island inside the panel, so the outer shadow isn't clipped.
    var shadowMargin: CGFloat {
        let r = theme.surface.shadow.outerRadius
        return r > 0 ? CGFloat(r * 2 + 2) : 0
    }

    /// Everything the window controller needs to size the panel. Reading this inside
    /// `withObservationTracking` re-lays out the panel whenever any input changes.
    var layout: PanelLayout {
        PanelLayout(
            frame: geometry.panelFrame(islandSize: islandSize, margin: shadowMargin, verticalOffset: CGFloat(theme.geometry.verticalOffset)),
            isSuppressed: isSuppressed
        )
    }
}

struct PanelLayout: Equatable {
    var frame: CGRect
    var isSuppressed: Bool
}

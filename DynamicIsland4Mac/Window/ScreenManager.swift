import AppKit
import Observation

/// Creates one island per eligible display and keeps the set in sync with the hardware.
///
/// Everything is event driven: screen changes (`didChangeScreenParametersNotification`),
/// Space and app switches (for full-screen detection), and preference changes. Nothing polls.
@MainActor
final class ScreenManager {
    private unowned let services: AppServices
    private(set) var controllers: [CGDirectDisplayID: IslandWindowController] = [:]
    private var observers: [NSObjectProtocol] = []

    init(services: AppServices) {
        self.services = services
    }

    var islands: [IslandViewModel] { controllers.values.map(\.model) }

    /// The island the keyboard shortcut toggles: the one on the display under the pointer,
    /// else the built-in display, else any.
    var primaryIsland: IslandViewModel? {
        let mouse = NSEvent.mouseLocation
        if let c = controllers.values.first(where: { $0.screen.frame.contains(mouse) }) { return c.model }
        if let c = controllers.values.first(where: { $0.screen.isBuiltIn }) { return c.model }
        return controllers.values.first?.model
    }

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Full-screen transitions finish a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.updateSuppression() }
            })
        }
        rebuild()
        observePreferences()
    }

    private func observePreferences() {
        withObservationTracking {
            let p = services.preferences.values
            _ = (p.displayMode, p.chosenDisplayName, p.hideFromScreenCapture, p.hideInFullScreen, p.hideWhenIdle)
            _ = services.themeStore.theme.geometry.pillWidth
            _ = services.themeStore.theme.geometry.pillHeight
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.rebuild()
                self?.observePreferences()
            }
        }
    }

    /// Screens that should get an island, per the display preference.
    func eligibleScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        let prefs = services.preferences.values
        switch prefs.displayMode {
        case .all:
            return screens
        case .chosen:
            if let match = screens.first(where: { $0.localizedName == prefs.chosenDisplayName }) { return [match] }
            return Array(screens.prefix(1))
        case .builtIn:
            let notched = screens.filter { $0.hasNotch }
            if !notched.isEmpty { return notched }
            if let builtIn = screens.first(where: { $0.isBuiltIn }) { return [builtIn] }
            // Lid closed: fall back to the main display's pill rather than showing nothing.
            return Array(screens.prefix(1))
        }
    }

    func rebuild() {
        let screens = eligibleScreens()
        var seen = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = IslandWindowController(screen: screen, services: services)
                Log.window.info("Island created on \(screen.localizedName, privacy: .public) (notch: \(screen.hasNotch))")
            }
        }
        for (id, controller) in controllers where !seen.contains(id) {
            controller.close()
            controllers.removeValue(forKey: id)
        }
        services.islandsDidChange()
        updateSuppression()
    }

    /// Hide islands on displays showing a full-screen app (if the user wants that), and idle
    /// pills (if the user wants that).
    func updateSuppression() {
        let prefs = services.preferences.values
        let fullScreenDisplays = prefs.hideInFullScreen ? FullScreenDetector.displaysWithFullScreenWindow() : []
        for (id, controller) in controllers {
            let model = controller.model
            let fullScreen = fullScreenDisplays.contains(id)
            let idlePill = prefs.hideWhenIdle && model.isFloating && model.state == .collapsed
            let suppressed = fullScreen || idlePill
            if model.isSuppressed != suppressed { model.isSuppressed = suppressed }
        }
    }
}

/// Detects full-screen windows without Screen Recording permission.
///
/// `CGWindowListCopyWindowInfo` returns window *bounds*, owner and layer for every app
/// without any permission (only window titles need Screen Recording). A layer-0 window of
/// the frontmost app that covers a whole display means that display is in full screen.
enum FullScreenDetector {
    static func displaysWithFullScreenWindow() -> Set<CGDirectDisplayID> {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result = Set<CGDirectDisplayID>()
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return [] }
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // CG window bounds use a top-left origin; convert to AppKit's bottom-left.
            let bounds = CGRect(x: cgBounds.minX, y: primaryHeight - cgBounds.maxY, width: cgBounds.width, height: cgBounds.height)
            for screen in screens where screen.frame.equalTo(bounds) {
                if let id = screen.displayID { result.insert(id) }
            }
        }
        return result
    }
}

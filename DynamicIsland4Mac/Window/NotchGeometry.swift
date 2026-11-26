import AppKit

/// Where the island lives on one display, in global (AppKit, bottom-left origin) coordinates.
///
/// Pure value math so it can be unit tested without a real screen: feed it the numbers
/// `NSScreen` reports and it returns the notch rectangle, or a floating pill rectangle for
/// displays that have no notch.
struct NotchGeometry: Equatable {
    enum Kind: Equatable {
        /// A hardware notch: the island hides behind it when collapsed.
        case notch
        /// No notch: a floating pill just below the menu bar.
        case pill
    }

    var kind: Kind
    /// The whole display frame.
    var screenFrame: CGRect
    /// The collapsed island: the notch itself, or the pill.
    var baseRect: CGRect
    /// Height of the menu bar on this display (used for the pill position and the compact height).
    var menuBarHeight: CGFloat

    var hasNotch: Bool { kind == .notch }
    /// Global y of the island's top edge (before the theme's vertical offset).
    var topY: CGFloat { baseRect.maxY }
    var centerX: CGFloat { baseRect.midX }

    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame`
    ///   - visibleFrame: `NSScreen.visibleFrame` (used to infer the menu bar height)
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` (0 on displays without a notch)
    ///   - auxiliaryLeft/Right: `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
    ///     (the menu bar areas on either side of the notch; `nil` when there is no notch)
    ///   - pillSize: size of the floating pill for displays without a notch
    static func compute(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryLeft: CGRect?,
        auxiliaryRight: CGRect?,
        pillSize: CGSize
    ) -> NotchGeometry {
        // The menu bar is whatever sits between the top of the visible frame and the top of
        // the screen. When the menu bar auto-hides this is 0, so assume the standard height.
        let reportedMenuBar = screenFrame.maxY - visibleFrame.maxY
        let menuBarHeight = reportedMenuBar > 4 ? reportedMenuBar : 24

        if let left = auxiliaryLeft, let right = auxiliaryRight, safeAreaTop > 0 {
            // The notch is the gap between the two auxiliary areas. Only their *widths* are
            // used: that works whether AppKit reports the rects relative to the screen or in
            // global coordinates (documentation is vague and it has differed in practice).
            let width = screenFrame.width - left.width - right.width
            let notchMinX = screenFrame.minX + left.width
            if width > 20 {
                let height = safeAreaTop
                let rect = CGRect(x: notchMinX, y: screenFrame.maxY - height, width: width, height: height)
                return NotchGeometry(kind: .notch, screenFrame: screenFrame, baseRect: rect.integral, menuBarHeight: max(menuBarHeight, height))
            }
        }

        // Floating pill: centered, a few points below the menu bar.
        let gap: CGFloat = 6
        let rect = CGRect(
            x: screenFrame.midX - pillSize.width / 2,
            y: screenFrame.maxY - menuBarHeight - gap - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        )
        return NotchGeometry(kind: .pill, screenFrame: screenFrame, baseRect: rect.integral, menuBarHeight: menuBarHeight)
    }

    @MainActor
    static func forScreen(_ screen: NSScreen, pillSize: CGSize) -> NotchGeometry {
        compute(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea,
            auxiliaryRight: screen.auxiliaryTopRightArea,
            pillSize: pillSize
        )
    }

    /// The panel frame for an island of `islandSize`, plus `margin` around the sides and
    /// bottom for shadows. The island is top-centered in the panel.
    func panelFrame(islandSize: CGSize, margin: CGFloat, verticalOffset: CGFloat) -> CGRect {
        let width = islandSize.width + margin * 2
        let height = islandSize.height + margin
        let top = topY - verticalOffset
        return CGRect(x: (centerX - width / 2).rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isBuiltIn: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }
}

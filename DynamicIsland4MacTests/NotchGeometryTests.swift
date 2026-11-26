import CoreGraphics
import Testing
@testable import DynamicIsland4Mac

/// Numbers as reported by a 14" MacBook Pro (1512×982 points, default scaling).
struct NotchGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let pill = CGSize(width: 190, height: 30)

    @Test func notchIsTheGapBetweenAuxiliaryAreas() {
        let left = CGRect(x: 0, y: 944, width: 662, height: 38)
        let right = CGRect(x: 850, y: 944, width: 662, height: 38)
        let g = NotchGeometry.compute(screenFrame: screen, visibleFrame: visible, safeAreaTop: 38,
                                      auxiliaryLeft: left, auxiliaryRight: right, pillSize: pill)
        #expect(g.kind == .notch)
        #expect(g.baseRect == CGRect(x: 662, y: 944, width: 188, height: 38))
        #expect(g.centerX == 756)
        #expect(g.topY == 982)
    }

    @Test func worksWithScreenRelativeAuxiliaryRectsOnSecondaryDisplay() {
        // A notched display placed to the right of another display: frame.minX = 1920.
        let frame = CGRect(x: 1920, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 944, width: 662, height: 38)       // relative
        let right = CGRect(x: 850, y: 944, width: 662, height: 38)
        let g = NotchGeometry.compute(screenFrame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 19).offsetBy(dx: 0, dy: -19),
                                      safeAreaTop: 38, auxiliaryLeft: left, auxiliaryRight: right, pillSize: pill)
        #expect(g.baseRect.minX == CGFloat(1920 + 662))
        #expect(g.baseRect.width == 188)
    }

    @Test func fallsBackToPillWithoutNotch() {
        let g = NotchGeometry.compute(screenFrame: screen, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957),
                                      safeAreaTop: 0, auxiliaryLeft: nil, auxiliaryRight: nil, pillSize: pill)
        #expect(g.kind == .pill)
        #expect(g.menuBarHeight == 25)
        #expect(g.baseRect.width == 190)
        #expect(g.baseRect.midX == 756)
        // 6 pt below the menu bar.
        #expect(g.baseRect.maxY == CGFloat(982 - 25 - 6))
    }

    @Test func pillAssumesStandardMenuBarWhenAutoHidden() {
        let g = NotchGeometry.compute(screenFrame: screen, visibleFrame: screen, safeAreaTop: 0,
                                      auxiliaryLeft: nil, auxiliaryRight: nil, pillSize: pill)
        #expect(g.menuBarHeight == 24)
    }

    @Test func panelFrameIsTopCenteredWithShadowMargin() {
        let left = CGRect(x: 0, y: 944, width: 662, height: 38)
        let right = CGRect(x: 850, y: 944, width: 662, height: 38)
        let g = NotchGeometry.compute(screenFrame: screen, visibleFrame: visible, safeAreaTop: 38,
                                      auxiliaryLeft: left, auxiliaryRight: right, pillSize: pill)
        let frame = g.panelFrame(islandSize: CGSize(width: 400, height: 200), margin: 10, verticalOffset: 0)
        #expect(frame.width == 420)
        #expect(frame.height == 210)
        #expect(frame.maxY == 982)
        #expect(frame.midX == 756)
        let offset = g.panelFrame(islandSize: CGSize(width: 400, height: 200), margin: 0, verticalOffset: 8)
        #expect(offset.maxY == 974)
    }
}

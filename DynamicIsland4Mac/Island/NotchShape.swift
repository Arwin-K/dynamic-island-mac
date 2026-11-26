import SwiftUI

/// The island outline.
///
/// Matches the hardware notch: straight sides, rounded bottom corners, and — at the top —
/// two small *inward* curves where the notch flares out to meet the top edge of the screen.
///
///     ╲___                            ___╱   ← topCurve: concave flare into the screen edge
///         │                          │
///         ╰──────────────────────────╯       ← bottomRadius
///
/// The flares sit *outside* the body, so the body width is `rect.width - 2 * topCurve`.
/// `IslandViewModel` adds `2 * topCurve` to the width it asks for, which keeps the body
/// exactly as wide as the notch.
///
/// For the floating pill on displays without a notch, set `topCurve` to 0 and
/// `topRadius` to a convex radius to round the top corners too.
///
/// Every radius is animatable, so springing between states morphs the outline smoothly.
struct NotchShape: Shape {
    var topCurve: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(topCurve, AnimatablePair(bottomRadius, topRadius)) }
        set {
            topCurve = newValue.first
            bottomRadius = newValue.second.first
            topRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCurve, rect.width / 4, rect.height / 2))
        let bodyMinX = rect.minX + top
        let bodyMaxX = rect.maxX - top
        let bodyWidth = bodyMaxX - bodyMinX
        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - top))
        let topR = max(0, min(topRadius, bodyWidth / 2, (rect.height - bottom)))

        var path = Path()
        if top > 0 {
            // Start on the screen's top edge, outside the body, and curve inward.
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: bodyMinX, y: rect.minY + top), control: CGPoint(x: bodyMinX, y: rect.minY))
        } else if topR > 0 {
            path.move(to: CGPoint(x: bodyMinX, y: rect.minY + topR))
        } else {
            path.move(to: CGPoint(x: bodyMinX, y: rect.minY))
        }

        // Left side down to the bottom-left corner.
        path.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: bodyMinX + bottom, y: rect.maxY), control: CGPoint(x: bodyMinX, y: rect.maxY))
        path.addLine(to: CGPoint(x: bodyMaxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: bodyMaxX, y: rect.maxY - bottom), control: CGPoint(x: bodyMaxX, y: rect.maxY))

        if top > 0 {
            path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: bodyMaxX, y: rect.minY))
        } else if topR > 0 {
            path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + topR))
            path.addQuadCurve(to: CGPoint(x: bodyMaxX - topR, y: rect.minY), control: CGPoint(x: bodyMaxX, y: rect.minY))
            path.addLine(to: CGPoint(x: bodyMinX + topR, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: bodyMinX, y: rect.minY + topR), control: CGPoint(x: bodyMinX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

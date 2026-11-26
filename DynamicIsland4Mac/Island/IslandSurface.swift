import AppKit
import SwiftUI

/// Draws the island's background (black, material, solid or gradient), border and shadows,
/// clipped to the animated `NotchShape`.
struct IslandSurface: View {
    let theme: Theme
    let palette: ResolvedPalette
    let shape: NotchShape
    /// In the collapsed state on a notched display the island must be invisible against the
    /// hardware, so it is always pure black with no border or shadow there.
    let blendsIntoNotch: Bool
    /// Increase Contrast: always draw a visible edge so the island separates from what's behind it.
    var increaseContrast = false

    var body: some View {
        let surface = theme.surface
        fill
            .opacity(blendsIntoNotch ? 1 : surface.opacity)
            .clipShape(shape)
            .overlay {
                if !blendsIntoNotch, surface.shadow.innerRadius > 0 {
                    shape
                        .stroke(palette.shadow.opacity(surface.shadow.innerOpacity), lineWidth: CGFloat(surface.shadow.innerRadius) * 2)
                        .blur(radius: CGFloat(surface.shadow.innerRadius))
                        .clipShape(shape)
                }
            }
            .overlay {
                if !blendsIntoNotch, surface.border.width > 0 || increaseContrast {
                    shape.stroke(palette.border.opacity(increaseContrast ? 1 : surface.border.opacity),
                                 lineWidth: max(CGFloat(surface.border.width), increaseContrast ? 1.5 : 0))
                }
            }
            .shadow(
                color: blendsIntoNotch ? .clear : palette.shadow.opacity(surface.shadow.outerOpacity),
                radius: blendsIntoNotch ? 0 : CGFloat(surface.shadow.outerRadius),
                y: blendsIntoNotch ? 0 : CGFloat(surface.shadow.outerRadius) * 0.35
            )
    }

    @ViewBuilder
    private var fill: some View {
        if blendsIntoNotch {
            Color.black
        } else {
            switch theme.surface.kind {
            case .black:
                Color.black
            case .solid:
                palette.surface
            case .gradient:
                LinearGradient(colors: [palette.gradientStart, palette.gradientEnd], startPoint: gradientPoints.start, endPoint: gradientPoints.end)
            case .material:
                ZStack {
                    VisualEffectBackground(material: theme.surface.material, isDark: palette.isDark)
                    palette.surface.opacity(0.18)
                }
            }
        }
    }

    private var gradientPoints: (start: UnitPoint, end: UnitPoint) {
        let radians = theme.surface.gradientAngle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return (UnitPoint(x: 0.5 - dx, y: 0.5 - dy), UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// System vibrancy behind the island. SwiftUI's `Material` blends *within* the window, which
/// in a transparent panel blurs nothing, so this uses `NSVisualEffectView` with
/// `.behindWindow` blending to blur the desktop and windows underneath.
struct VisualEffectBackground: NSViewRepresentable {
    let material: Surface.MaterialKind
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { update(view) }

    private func update(_ view: NSVisualEffectView) {
        // AppKit has no "ultraThin…ultraThick" scale; these are the closest system materials,
        // ordered from most to least see-through.
        switch material {
        case .ultraThin: view.material = .fullScreenUI
        case .thin: view.material = .hudWindow
        case .regular: view.material = .popover
        case .thick: view.material = .menu
        case .ultraThick: view.material = .windowBackground
        }
        view.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }
}

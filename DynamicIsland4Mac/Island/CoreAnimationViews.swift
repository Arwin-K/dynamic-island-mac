import AppKit
import QuartzCore
import SwiftUI

// Continuous animations (the waveform, the "thinking" pulse) are done with Core Animation
// instead of SwiftUI `TimelineView` / `repeatForever`. SwiftUI re-evaluates views on every
// frame or tick of those, which costs 10–20% CPU for a few bars; a `CABasicAnimation` is
// run by the window server's render process, so the app itself does no work while it plays.

/// Bars that bounce while `isAnimating`. Static (short) bars otherwise or with Reduce Motion.
struct WaveformBars: NSViewRepresentable {
    var isAnimating: Bool
    var color: Color
    var barCount = 4

    func makeNSView(context: Context) -> WaveformLayerView {
        WaveformLayerView(barCount: barCount)
    }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.update(color: NSColor(color), animating: isAnimating && !reduceMotion)
    }
}

final class WaveformLayerView: NSView {
    private var bars: [CALayer] = []
    private var animating = false
    private var color: NSColor = .white

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let count = CGFloat(bars.count)
        let gap = bounds.width * 0.12
        let width = max(1, (bounds.width - gap * (count - 1)) / count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + gap) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
            bar.backgroundColor = color.cgColor
            if !animating { bar.transform = CATransform3DMakeScale(1, 0.3, 1) }
        }
        CATransaction.commit()
    }

    func update(color: NSColor, animating: Bool) {
        self.color = color
        bars.forEach { $0.backgroundColor = color.cgColor }
        guard animating != self.animating else { return }
        self.animating = animating
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if animating {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.25
                a.toValue = 1.0
                a.duration = 0.32 + Double(i) * 0.09
                a.timeOffset = Double(i) * 0.13
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(a, forKey: "bounce")
                bar.transform = CATransform3DIdentity
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }
}

/// A dot that slowly pulses (agent thinking). Static with Reduce Motion.
struct PulsingDot: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.update(color: NSColor(color), animating: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class PulsingDotView: NSView {
    private let dot = CALayer()
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        dot.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        dot.cornerRadius = side / 2
        CATransaction.commit()
    }

    func update(color: NSColor, animating: Bool) {
        dot.backgroundColor = color.cgColor
        guard animating != self.animating else { return }
        self.animating = animating
        dot.removeAllAnimations()
        if animating {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.3
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = .infinity
            dot.add(a, forKey: "pulse")
        }
    }
}

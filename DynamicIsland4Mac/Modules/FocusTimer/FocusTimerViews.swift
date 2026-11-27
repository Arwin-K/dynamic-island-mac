import AppKit
import QuartzCore
import SwiftUI

/// "24:59" counting down while running (system-driven text, no view refresh), static when paused.
struct FocusTimeText: View {
    let module: FocusTimerModule
    /// nil = compact size from the theme.
    let size: CGFloat?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let font = theme.font(size: size ?? theme.typography.bodySize, weight: size == nil ? .semibold : .bold, monospacedDigits: true)
        Group {
            if let endsAt = module.endsAt {
                Text(timerInterval: Date()...max(endsAt, Date()), countsDown: true)
            } else {
                Text(Self.format(module.remaining()))
            }
        }
        .font(font)
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
        .accessibilityLabel("\(Self.format(module.remaining())) left")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct FocusTimerExpandedView: View {
    let module: FocusTimerModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                FocusRing(progress: module.remaining() / max(module.sessionLength, 1),
                          endsAt: module.endsAt, lineWidth: 6, glow: module.isRunning)
                if module.isActive {
                    FocusTimeText(module: module, size: 17)
                } else {
                    Image(systemName: "timer")
                        .font(.system(size: 22, weight: theme.icons.weight.weight))
                        .foregroundStyle(palette.accent)
                }
            }
            .frame(width: 86, height: 86)
            .islandMatched("ring", module: module.id)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(theme.titleFont)
                    Text(subtitle)
                        .font(theme.captionFont)
                        .foregroundStyle(palette.secondary)
                }
                if module.isActive {
                    HStack(spacing: 8) {
                        if module.isRunning {
                            pill("pause.fill", "Pause") { module.pause() }
                        } else {
                            pill("play.fill", "Resume", prominent: true) { module.resume() }
                        }
                        pill("plus", "5 min") { module.addFiveMinutes() }
                        pill("stop.fill", "Stop") { module.reset() }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach(FocusTimerModule.presets, id: \.self) { preset in
                            let selected = Int(module.minutes) == Int(preset)
                            Button {
                                module.selectPreset(preset)
                            } label: {
                                Text("\(Int(preset))m")
                                    .font(theme.font(size: theme.typography.captionSize, weight: .semibold, monospacedDigits: true))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(selected ? palette.accent.opacity(0.9) : palette.foreground.opacity(0.1)))
                                    .foregroundStyle(selected ? Color.white : palette.foreground)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Int(preset)) minutes")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        pill("play.fill", "Start", prominent: true) { module.beginSession() }
                    }
                }
                SessionDots(count: module.completedToday)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: module.isRunning)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: module.isPaused)
    }

    private var title: String {
        if module.isRunning { return "Focusing" }
        if module.isPaused { return "Paused" }
        return "Ready to focus"
    }

    private var subtitle: String {
        if let endsAt = module.endsAt { return "Ends at \(endsAt.formatted(date: .omitted, time: .shortened))" }
        if module.isPaused { return "\(FocusTimeText.format(module.remaining())) left" }
        return "Pick a length and start"
    }

    private func pill(_ symbol: String, _ label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(theme.font(size: theme.typography.captionSize, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(prominent ? palette.accent.opacity(0.9) : palette.foreground.opacity(0.1)))
                .foregroundStyle(prominent ? Color.white : palette.foreground)
        }
        .buttonStyle(.plain)
    }
}

/// One dot per session finished today (up to 8, then a number).
private struct SessionDots: View {
    let count: Int
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(count, 8), id: \.self) { _ in
                Circle().fill(palette.accent).frame(width: 6, height: 6)
            }
            Text(count == 0 ? "No sessions yet today" : (count == 1 ? "1 session today" : "\(count) sessions today"))
                .font(theme.captionFont)
                .foregroundStyle(palette.secondary)
                .padding(.leading, count > 0 ? 2 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 session finished today" : "\(count) sessions finished today")
    }
}

struct FocusDoneAlert: View {
    let count: Int
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus session done").font(theme.titleFont)
                Text(count == 1 ? "First one today. Take a short break." : "\(count) today. Take a short break.")
                    .font(theme.captionFont)
                    .foregroundStyle(palette.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A ring that drains to zero by `endsAt`, animated by Core Animation over the whole remaining
/// time, so the app does no work while it runs. Static when paused or idle.
struct FocusRing: NSViewRepresentable {
    var progress: Double
    var endsAt: Date?
    var lineWidth: CGFloat
    var glow = false
    @Environment(\.islandPalette) private var palette

    func makeNSView(context: Context) -> FocusRingView { FocusRingView() }

    func updateNSView(_ view: FocusRingView, context: Context) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.update(progress: min(max(progress, 0), 1), endsAt: endsAt, lineWidth: lineWidth,
                    color: NSColor(palette.accent), track: NSColor(palette.foreground.opacity(0.15)),
                    glow: glow && !reduceMotion)
    }
}

final class FocusRingView: NSView {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let halo = CAShapeLayer()
    private var lastEndsAt: Date?
    private var lineWidth: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [halo, track, ring] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        halo.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Start at 12 o'clock and run clockwise (AppKit's y axis points up).
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [halo, track, ring] {
            l.frame = bounds
            l.path = path
        }
        CATransaction.commit()
    }

    func update(progress: Double, endsAt: Date?, lineWidth: CGFloat, color: NSColor, track trackColor: NSColor, glow: Bool) {
        if self.lineWidth != lineWidth {
            self.lineWidth = lineWidth
            needsLayout = true
        }
        track.lineWidth = lineWidth
        ring.lineWidth = lineWidth
        halo.lineWidth = lineWidth * 2.2
        track.strokeColor = trackColor.cgColor
        ring.strokeColor = color.cgColor
        halo.strokeColor = color.withAlphaComponent(0.35).cgColor

        // Draining: one animation from the current fraction to 0 over the remaining time.
        if endsAt != lastEndsAt {
            lastEndsAt = endsAt
            ring.removeAnimation(forKey: "drain")
            ring.strokeEnd = CGFloat(progress)
            if let endsAt {
                let remaining = max(0.1, endsAt.timeIntervalSinceNow)
                ring.strokeEnd = 0
                let drain = CABasicAnimation(keyPath: "strokeEnd")
                drain.fromValue = progress
                drain.toValue = 0
                drain.duration = remaining
                drain.timingFunction = CAMediaTimingFunction(name: .linear)
                ring.add(drain, forKey: "drain")
            }
        } else if endsAt == nil {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            ring.strokeEnd = CGFloat(progress)
            CATransaction.commit()
        }

        // A slow "breathing" halo while running.
        if glow, halo.animation(forKey: "breathe") == nil {
            halo.strokeEnd = 1
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.15
            breathe.toValue = 0.7
            breathe.duration = 2.2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(breathe, forKey: "breathe")
        } else if !glow {
            halo.removeAllAnimations()
            halo.opacity = 0
        }
    }
}

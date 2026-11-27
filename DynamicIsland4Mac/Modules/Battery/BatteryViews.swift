import SwiftUI

/// A battery outline with a fill. Green while charging, red when low, accent otherwise.
struct BatteryGlyph: View {
    let level: Double
    let charging: Bool
    let low: Bool
    @Environment(\.islandPalette) private var palette

    var fillColor: Color { charging ? .green : (low ? .red : palette.foreground) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let tipWidth = max(1.5, w * 0.07)
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: h * 0.3)
                        .stroke(palette.foreground.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: h * 0.2)
                        .fill(fillColor)
                        .frame(width: max(2, (w - tipWidth - 4) * level))
                        .padding(2)
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.7, weight: .bold))
                            .foregroundStyle(palette.foreground)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.foreground.opacity(0.45))
                    .frame(width: tipWidth, height: h * 0.4)
            }
        }
    }
}

struct BatteryPercentText: View {
    let level: Double
    let low: Bool
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        Text("\(Int((level * 100).rounded()))%")
            .font(theme.font(size: theme.typography.bodySize, weight: .semibold, monospacedDigits: true))
            .foregroundStyle(low ? .red : palette.foreground)
    }
}

/// The battery page: an animated battery (fill sweeps up on open, shimmer while charging,
/// red breathing when low), the percentage, status, and live stats. Animations are Core
/// Animation; the stats refresh every 5 s only while this page is on screen.
struct BatteryExpandedView: View {
    let service: BatteryService
    let isLow: Bool
    let moduleID: String
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let snapshot = service.snapshot
        let details = service.details
        let charging = snapshot.isCharging || (snapshot.isPluggedIn && !snapshot.isCharged && snapshot.level < 0.995)
        HStack(spacing: 18) {
            BatteryHero(level: snapshot.level, charging: charging, pluggedIn: snapshot.isPluggedIn, low: isLow)
                .frame(width: 104, height: 50)
                .islandMatched("glyph", module: moduleID)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int((snapshot.level * 100).rounded()))%")
                        .font(theme.font(size: 30, weight: .bold, monospacedDigits: true))
                        .contentTransition(.numericText())
                    Text(statusText(snapshot))
                        .font(theme.captionFont)
                        .foregroundStyle(charging ? Color.green : (isLow ? Color.red : palette.secondary))
                        .lineLimit(1)
                }
                FlowChips(chips: chips(snapshot, details))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: snapshot.level)
        .task {
            // Wattage changes continuously and isn't pushed by IOKit, so refresh it while visible.
            while !Task.isCancelled {
                service.refreshDetails()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ s: BatteryService.Snapshot) -> String {
        if s.isCharged || (s.isPluggedIn && s.level >= 0.995) { return "Fully charged" }
        if s.isCharging {
            if let m = s.minutesToFull { return "\(Self.format(m)) until full" }
            return "Charging"
        }
        if s.isPluggedIn { return "Plugged in, not charging" }
        if let m = s.minutesToEmpty { return "\(Self.format(m)) left" }
        return "On battery"
    }

    private func chips(_ s: BatteryService.Snapshot, _ d: BatteryService.Details) -> [StatChip] {
        var chips: [StatChip] = []
        if let w = d.batteryWatts {
            chips.append(StatChip(symbol: w > 0 ? "bolt.fill" : "gauge.with.dots.needle.33percent",
                                  text: String(format: w > 0 ? "Charging %.1f W" : "Using %.1f W", abs(w)),
                                  label: w > 0 ? "Charging at" : "Using", tint: w > 0 ? .green : nil))
        }
        if let a = d.adapterWatts, s.isPluggedIn {
            chips.append(StatChip(symbol: "powerplug.fill", text: "\(a) W adapter", label: "Adapter", tint: nil))
        }
        if let h = d.healthPercent {
            chips.append(StatChip(symbol: "heart.fill", text: "\(h)% health", label: "Battery health", tint: h < 80 ? .orange : nil))
        }
        if let c = d.cycleCount {
            chips.append(StatChip(symbol: "arrow.triangle.2.circlepath", text: "\(c) cycles", label: "Cycle count", tint: nil))
        }
        if let t = d.temperatureCelsius {
            chips.append(StatChip(symbol: "thermometer.medium", text: String(format: "%.0f°C", t), label: "Temperature", tint: t > 40 ? .orange : nil))
        }
        if s.lowPowerMode {
            chips.append(StatChip(symbol: "leaf.fill", text: "Low Power", label: "Low Power Mode", tint: .yellow))
        }
        return chips
    }

    static func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct StatChip: Identifiable, Equatable {
    var symbol: String
    var text: String
    var label: String
    var tint: Color?
    var id: String { label }
}

/// Chips in rows of two, so the page stays compact.
private struct FlowChips: View {
    let chips: [StatChip]
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let rows = stride(from: 0, to: chips.count, by: 2).map { Array(chips[$0..<min($0 + 2, chips.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    ForEach(rows[i]) { chip in
                        Label(chip.text, systemImage: chip.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(theme.font(size: theme.typography.captionSize, weight: .medium, monospacedDigits: true))
                            .foregroundStyle(chip.tint ?? palette.foreground.opacity(0.85))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill((chip.tint ?? palette.foreground).opacity(0.12)))
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(chip.label): \(chip.text)")
                    }
                }
            }
        }
    }
}

/// The big battery: SwiftUI outline and bolt around a Core Animation fill.
struct BatteryHero: View {
    let level: Double
    let charging: Bool
    let pluggedIn: Bool
    let low: Bool
    @Environment(\.islandPalette) private var palette

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let tip = max(3, geo.size.width * 0.06)
            HStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: h * 0.24, style: .continuous)
                        .stroke(palette.foreground.opacity(0.4), lineWidth: 1.5)
                    BatteryFill(level: level, charging: charging, low: low)
                        .padding(4)
                    if pluggedIn {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.46, weight: .heavy))
                            .foregroundStyle(palette.foreground)
                            .shadow(color: .black.opacity(0.55), radius: 2)
                    }
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.foreground.opacity(0.4))
                    .frame(width: tip, height: h * 0.36)
            }
        }
    }
}

/// The fill of the big battery, animated by Core Animation:
/// * sweeps up from empty when it appears, and springs to new levels;
/// * a soft highlight travels across it while charging;
/// * breathes red when low.
/// Reduce Motion keeps it static.
struct BatteryFill: NSViewRepresentable {
    let level: Double
    let charging: Bool
    let low: Bool
    @Environment(\.islandPalette) private var palette

    func makeNSView(context: Context) -> BatteryFillView { BatteryFillView() }

    func updateNSView(_ view: BatteryFillView, context: Context) {
        let color: NSColor = charging ? .systemGreen : (low ? .systemRed : NSColor(palette.foreground))
        view.update(level: level, color: color, charging: charging, low: low,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class BatteryFillView: NSView {
    private let fill = CALayer()
    private let shimmer = CAGradientLayer()
    private var level: Double = 0
    private var hasAppeared = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.masksToBounds = true
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        shimmer.locations = [0, 0.5, 1]
        shimmer.opacity = 0
        fill.addSublayer(shimmer)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.cornerRadius = bounds.height * 0.18
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * level, height: bounds.height)
        shimmer.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.45, height: bounds.height)
        CATransaction.commit()
        if !hasAppeared, bounds.width > 0 {
            hasAppeared = true
            sweepIn()
        }
    }

    private func sweepIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let sweep = CABasicAnimation(keyPath: "bounds.size.width")
        sweep.fromValue = 0
        sweep.toValue = bounds.width * level
        sweep.duration = 0.9
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        fill.add(sweep, forKey: "sweep")
    }

    func update(level: Double, color: NSColor, charging: Bool, low: Bool, reduceMotion: Bool) {
        let clamped = min(max(level, 0.02), 1)
        fill.backgroundColor = color.cgColor
        if clamped != self.level {
            self.level = clamped
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
            CATransaction.commit()
        }

        if charging && !reduceMotion {
            if shimmer.animation(forKey: "travel") == nil {
                shimmer.opacity = 1
                let travel = CABasicAnimation(keyPath: "position.x")
                travel.fromValue = -bounds.width * 0.25
                travel.toValue = bounds.width * 1.25
                travel.duration = 1.8
                travel.repeatCount = .infinity
                travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shimmer.add(travel, forKey: "travel")
            }
        } else {
            shimmer.removeAllAnimations()
            shimmer.opacity = 0
        }

        if low && !charging && !reduceMotion {
            if fill.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1
                breathe.toValue = 0.45
                breathe.duration = 1.1
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                fill.add(breathe, forKey: "breathe")
            }
        } else {
            fill.removeAnimation(forKey: "breathe")
        }
    }
}

/// The alert shown when the charger connects or the battery runs low.
struct BatteryAlertView: View {
    enum Kind { case charging, low }
    let level: Double
    let kind: Kind
    @State private var animatedLevel: Double = 0
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            BatteryGlyph(level: kind == .charging ? animatedLevel : level, charging: kind == .charging, low: kind == .low)
                .frame(width: 44, height: 20)
            Text(kind == .charging ? "Charging" : "Battery Low")
                .font(theme.titleFont)
            Spacer()
            Text("\(Int((level * 100).rounded()))%")
                .font(theme.font(size: theme.typography.titleSize, weight: .bold, monospacedDigits: true))
                .foregroundStyle(kind == .low ? .red : .green)
        }
        .padding(.horizontal, 6)
        .onAppear {
            guard kind == .charging else { return }
            if reduceMotion {
                animatedLevel = level
            } else {
                animatedLevel = max(0, level - 0.25)
                withAnimation(.easeOut(duration: 1.1)) { animatedLevel = level }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind == .charging ? "Charging, \(Int(level * 100)) percent" : "Battery low, \(Int(level * 100)) percent")
    }
}

struct BatterySettingsView: View {
    let context: ModuleContext

    var body: some View {
        Toggle("Always show battery in the compact island", isOn: context.boolBinding("alwaysShow", default: false))
        Toggle("Charging animation when the charger connects", isOn: context.boolBinding("chargeAnimation", default: true))
        ValueSlider(title: "Low battery alert at", value: context.doubleBinding("lowThreshold", default: 20), range: 5...50, step: 5, format: "%.0f%%")
    }
}

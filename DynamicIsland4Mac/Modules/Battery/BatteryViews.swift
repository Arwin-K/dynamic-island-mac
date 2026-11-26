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

struct BatteryExpandedView: View {
    let snapshot: BatteryService.Snapshot
    let isLow: Bool
    let moduleID: String
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 18) {
            BatteryGlyph(level: snapshot.level, charging: snapshot.isCharging || snapshot.isPluggedIn, low: isLow)
                .frame(width: 92, height: 42)
                .islandMatched("glyph", module: moduleID)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Int((snapshot.level * 100).rounded()))%")
                    .font(theme.font(size: 28, weight: .bold, monospacedDigits: true))
                Text(statusText)
                    .font(theme.bodyFont)
                    .foregroundStyle(palette.secondary)
                if snapshot.lowPowerMode {
                    Label("Low Power Mode", systemImage: "leaf.fill")
                        .font(theme.captionFont)
                        .foregroundStyle(.yellow)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if snapshot.isCharged || (snapshot.isPluggedIn && snapshot.level >= 0.995) { return "Fully charged" }
        if snapshot.isCharging {
            if let m = snapshot.minutesToFull { return "Charging · \(Self.format(m)) until full" }
            return "Charging"
        }
        if snapshot.isPluggedIn { return "Plugged in, not charging" }
        if let m = snapshot.minutesToEmpty { return "\(Self.format(m)) remaining" }
        return "On battery"
    }

    static func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
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

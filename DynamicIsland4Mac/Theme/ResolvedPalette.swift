import SwiftUI

/// The colors a view actually draws with: the theme's light or dark `ColorSet`, with the
/// accent replaced by a live source (system accent, wallpaper, album art) when configured,
/// and adjusted for Increase Contrast.
struct ResolvedPalette: Equatable {
    var isDark: Bool
    var foreground: Color
    var secondary: Color
    var accent: Color
    var surface: Color
    var gradientStart: Color
    var gradientEnd: Color
    var border: Color
    var shadow: Color

    init(theme: Theme, isDark: Bool, accentOverride: HexColor? = nil, increaseContrast: Bool = false) {
        let set = isDark ? theme.colors.dark : theme.colors.light
        self.isDark = isDark
        foreground = set.foreground.color
        // Increase Contrast: secondary text becomes full-strength foreground.
        secondary = increaseContrast ? set.foreground.color : set.secondary.color
        accent = (accentOverride ?? set.accent).color
        surface = set.surface.color
        gradientStart = set.gradientStart.color
        gradientEnd = set.gradientEnd.color
        border = increaseContrast ? set.foreground.color.opacity(0.6) : set.border.color
        shadow = set.shadow.color
    }

    /// The accent color for an agent provider: the theme's per-provider override, else the
    /// provider's built-in color.
    static func providerAccent(theme: Theme, providerID: String, fallback: Color) -> Color {
        theme.providers[providerID]?.accent?.color ?? fallback
    }
}

extension Theme {
    /// Resolve the theme's font settings into a SwiftUI font.
    func font(size: Double, weight: FontWeightName, monospacedDigits: Bool = false) -> Font {
        var font: Font
        switch typography.family {
        case "system", "":
            font = .system(size: size, weight: weight.weight, design: .default)
        case "system-rounded":
            font = .system(size: size, weight: weight.weight, design: .rounded)
        case "system-mono":
            font = .system(size: size, weight: weight.weight, design: .monospaced)
        case "system-serif":
            font = .system(size: size, weight: weight.weight, design: .serif)
        default:
            font = .custom(typography.family, size: size).weight(weight.weight)
        }
        if monospacedDigits && typography.monospacedDigits { font = font.monospacedDigit() }
        return font
    }

    var titleFont: Font { font(size: typography.titleSize, weight: typography.titleWeight) }
    var bodyFont: Font { font(size: typography.bodySize, weight: typography.bodyWeight) }
    var captionFont: Font { font(size: typography.captionSize, weight: typography.bodyWeight) }
    /// For timers and counters: monospaced digits when the theme asks for them.
    var timerFont: Font { font(size: typography.captionSize, weight: .medium, monospacedDigits: true) }
}

import SwiftUI

/// Every visual and motion choice the island makes. Themes are plain JSON files; see
/// `Themes/README.md` for every key. Decoding goes through `TolerantDecoder`, so any
/// key may be missing (the default below is used) and unknown keys are ignored.
///
/// Adding a property: give it a default value here, document it in `Themes/README.md`,
/// and old theme files keep working.
struct Theme: Codable, Equatable, Identifiable, Sendable {
    var id: String = "stealth"
    var name: String = "Stealth"
    var author: String = "DynamicIsland4Mac"
    var surface = Surface()
    var colors = Colors()
    var appearance: AppearanceMode = .system
    var typography = Typography()
    var geometry = Geometry()
    var motion = Motion()
    var icons = Icons()
    var feedback = Feedback()
    /// Per agent provider overrides, keyed by provider id (`"claude-code"`, `"codex"`).
    var providers: [String: ProviderStyle] = [:]

    static let `default` = Theme()
}

enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

// MARK: - Surface

struct Surface: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Pure black: melts into the hardware notch.
        case black
        /// System vibrancy (blurs whatever is behind the island).
        case material
        case solid
        case gradient
    }

    enum MaterialKind: String, Codable, CaseIterable, Sendable {
        case ultraThin, thin, regular, thick, ultraThick
    }

    var kind: Kind = .black
    var material: MaterialKind = .regular
    /// 0...1, applied to the whole surface (not the content).
    var opacity: Double = 1
    /// Degrees; 90 = top to bottom.
    var gradientAngle: Double = 90
    var border = Border()
    var shadow = Shadow()
}

struct Border: Codable, Equatable, Sendable {
    var width: Double = 0
    var opacity: Double = 1
}

struct Shadow: Codable, Equatable, Sendable {
    var outerRadius: Double = 0
    var outerOpacity: Double = 0.45
    var innerRadius: Double = 0
    var innerOpacity: Double = 0.35
}

// MARK: - Colors

struct Colors: Codable, Equatable, Sendable {
    enum AccentSource: String, Codable, CaseIterable, Sendable {
        /// The theme's own `accent` color.
        case fixed
        /// `NSColor.controlAccentColor`, updates live when you change it in System Settings.
        case system
        /// Sampled from the current desktop picture.
        case wallpaper
        /// Sampled from the artwork of whatever is playing (falls back to `fixed`).
        case albumArt
    }

    enum SampleStyle: String, Codable, CaseIterable, Sendable {
        /// The average color, weighted by area.
        case dominant
        /// The most saturated, mid-brightness color.
        case vibrant
    }

    var accentSource: AccentSource = .fixed
    var sampleStyle: SampleStyle = .vibrant
    var dark = ColorSet.darkDefault
    var light = ColorSet.lightDefault
}

/// One appearance variant. Themes may define both `dark` and `light`; which one is used
/// depends on `appearance` and the system setting.
struct ColorSet: Codable, Equatable, Sendable {
    var foreground: HexColor
    var secondary: HexColor
    var accent: HexColor
    /// Used when `surface.kind` is `solid`, and as the tint over materials.
    var surface: HexColor
    var gradientStart: HexColor
    var gradientEnd: HexColor
    var border: HexColor
    var shadow: HexColor

    static let darkDefault = ColorSet(
        foreground: .white,
        secondary: HexColor(red: 1, green: 1, blue: 1, alpha: 0.6),
        accent: HexColor(hex: "#0A84FF") ?? .white,
        surface: .black,
        gradientStart: HexColor(hex: "#1C1C1E") ?? .black,
        gradientEnd: .black,
        border: HexColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        shadow: .black
    )

    static let lightDefault = ColorSet(
        foreground: HexColor(hex: "#1D1D1F") ?? .black,
        secondary: HexColor(red: 0, green: 0, blue: 0, alpha: 0.55),
        accent: HexColor(hex: "#007AFF") ?? .black,
        surface: HexColor(hex: "#F5F5F7") ?? .white,
        gradientStart: .white,
        gradientEnd: HexColor(hex: "#E5E5EA") ?? .white,
        border: HexColor(red: 0, green: 0, blue: 0, alpha: 0.12),
        shadow: HexColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    )
}

// MARK: - Typography

enum FontWeightName: String, Codable, CaseIterable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    var weight: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

struct Typography: Codable, Equatable, Sendable {
    /// `"system"` (SF Pro), `"system-rounded"` (SF Rounded), `"system-mono"` (SF Mono),
    /// `"system-serif"` (New York), or the family name of any installed font.
    var family: String = "system"
    var titleSize: Double = 13
    var bodySize: Double = 12
    var captionSize: Double = 10.5
    var titleWeight: FontWeightName = .semibold
    var bodyWeight: FontWeightName = .regular
    var monospacedDigits: Bool = true

    static let quickPicks: [(label: String, family: String)] = [
        ("SF Pro", "system"), ("SF Rounded", "system-rounded"),
        ("SF Mono", "system-mono"), ("New York", "system-serif"),
    ]
}

// MARK: - Geometry

struct Geometry: Codable, Equatable, Sendable {
    /// Width added on each side of the notch in the compact state.
    var compactSideWidth: Double = 68
    /// Width and height of the expanded panel. Height is measured below the notch.
    var expandedWidth: Double = 400
    var expandedHeight: Double = 120
    /// Alert size. Height is measured below the notch.
    var alertWidth: Double = 360
    var alertHeight: Double = 56
    var collapsedBottomRadius: Double = 9
    /// When collapsed on a notched display, how far the island reaches past the hardware
    /// notch on each side and below it, so it visibly hugs the notch. 0 = exactly the notch.
    var collapsedSideOutset: Double = 8
    var collapsedBottomOutset: Double = 4
    var compactBottomRadius: Double = 12
    var expandedBottomRadius: Double = 28
    /// Depth of the small inward curves where the island meets the top edge of the screen.
    var topCurveDepth: Double = 6
    var padding: Double = 14
    /// Moves the island down from the top of the screen (0 = flush with the notch).
    var verticalOffset: Double = 0
    /// Size of the floating pill on displays without a notch.
    var pillWidth: Double = 190
    var pillHeight: Double = 30
}

// MARK: - Motion

struct Motion: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        case snappy, bouncy, smooth, instant, custom

        var label: String {
            switch self {
            case .snappy: "Snappy"
            case .bouncy: "Bouncy / iOS-like"
            case .smooth: "Smooth"
            case .instant: "Instant"
            case .custom: "Custom"
            }
        }
    }

    var preset: Preset = .snappy
    /// Used when `preset` is `custom`. Seconds for one oscillation.
    var response: Double = 0.38
    /// Used when `preset` is `custom`. 1 = no bounce.
    var damping: Double = 0.8
    /// Seconds the pointer must rest on the island before it opens.
    var hoverDelay: Double = 0.12
    /// Seconds after the pointer leaves before the island closes.
    var autoCollapseDelay: Double = 0.35
    /// Seconds an alert stays up.
    var alertDuration: Double = 3.5

    var springParameters: (response: Double, damping: Double)? {
        switch preset {
        case .snappy: (0.32, 0.86)
        case .bouncy: (0.48, 0.66)
        case .smooth: (0.6, 1.0)
        case .instant: nil
        case .custom: (max(response, 0.05), min(max(damping, 0.1), 1.5))
        }
    }

    /// Springs normally; a short fade when Reduce Motion is on; nothing for `instant`.
    func animation(reduceMotion: Bool) -> Animation? {
        guard let p = springParameters else { return nil }
        if reduceMotion { return .easeInOut(duration: 0.18) }
        return .spring(response: p.response, dampingFraction: p.damping)
    }

    /// Roughly how long the state animation takes to settle, used to delay shrinking
    /// the window until the shape has finished shrinking.
    func settleDuration(reduceMotion: Bool) -> Double {
        guard let p = springParameters else { return 0 }
        if reduceMotion { return 0.2 }
        return p.response * (p.damping >= 1 ? 1.2 : 1.6)
    }
}

// MARK: - Icons, feedback, providers

struct Icons: Codable, Equatable, Sendable {
    enum Rendering: String, Codable, CaseIterable, Sendable {
        case monochrome, hierarchical, palette, multicolor

        var mode: SymbolRenderingMode {
            switch self {
            case .monochrome: .monochrome
            case .hierarchical: .hierarchical
            case .palette: .palette
            case .multicolor: .multicolor
            }
        }
    }

    var weight: FontWeightName = .medium
    var rendering: Rendering = .hierarchical
}

struct SoundSetting: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// The name of a system sound in /System/Library/Sounds (e.g. "Glass", "Funk").
    var sound: String = "Glass"

    init(enabled: Bool = false, sound: String = "Glass") {
        self.enabled = enabled
        self.sound = sound
    }

    /// Lives inside a dictionary, so missing keys get their defaults here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        sound = (try? c.decodeIfPresent(String.self, forKey: .sound)) ?? "Glass"
    }
}

struct Feedback: Codable, Equatable, Sendable {
    /// Trackpad haptics on alerts. Only felt while a finger rests on a Force Touch trackpad.
    var haptics: Bool = true
    /// Keyed by event id, see `FeedbackEvent`.
    var sounds: [String: SoundSetting] = [
        FeedbackEvent.agentPermission.rawValue: SoundSetting(enabled: true, sound: "Funk"),
        FeedbackEvent.agentDone.rawValue: SoundSetting(enabled: false, sound: "Glass"),
    ]

    func sound(for event: FeedbackEvent) -> SoundSetting {
        sounds[event.rawValue] ?? SoundSetting()
    }
}

/// Events that can play a sound or haptic. Ids are stable; they appear in theme files.
enum FeedbackEvent: String, CaseIterable, Sendable {
    case agentPermission = "agent.permission"
    case agentIdle = "agent.idle"
    case agentDone = "agent.done"
    case agentFailed = "agent.failed"
    case trackChanged = "media.trackChanged"
    case batteryLow = "battery.low"
    case batteryCharging = "battery.charging"
    case calendarSoon = "calendar.soon"
    case hud = "hud"

    var label: String {
        switch self {
        case .agentPermission: "Agent needs permission"
        case .agentIdle: "Agent waiting for input"
        case .agentDone: "Agent finished"
        case .agentFailed: "Agent failed"
        case .trackChanged: "Track changed"
        case .batteryLow: "Battery low"
        case .batteryCharging: "Charger connected"
        case .calendarSoon: "Event starting soon"
        case .hud: "Volume / brightness"
        }
    }
}

struct ProviderStyle: Codable, Equatable, Sendable {
    var accent: HexColor?
    /// An SF Symbol name that replaces the provider's default icon.
    var symbol: String?
}

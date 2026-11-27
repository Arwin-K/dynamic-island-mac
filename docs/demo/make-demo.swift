// Renders the DynamicIsland4Mac demo video, frame by frame, from a scripted timeline.
//
//   swiftc -O -parse-as-library docs/demo/make-demo.swift -o /tmp/make-demo
//   /tmp/make-demo docs/demo/DynamicIsland4Mac-demo.mp4          # full video
//   /tmp/make-demo /tmp/stills --stills 5 17.5 30                 # PNG stills at those times
//
// Everything on screen is drawn here in SwiftUI (a mock MacBook desktop with a recreation of
// the island), so the video is reproducible and shows no real user data. The "Cursorful"
// style: the screen sits in a rounded frame on a gradient, the camera zooms toward each
// interaction, the cursor glides with click ripples, and key presses get an overlay.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Configuration

let frameSize = CGSize(width: 1920, height: 1080)
let fps = 60
let duration = 65.0
/// The virtual MacBook Pro screen, in points.
let S = CGSize(width: 1512, height: 982)
let cx: CGFloat = 756
let notchW: CGFloat = 186
let notchH: CGFloat = 32
let viewport: CGRect = {
    let h: CGFloat = 930
    let w = h * S.width / S.height
    return CGRect(x: (frameSize.width - w) / 2, y: 44, width: w, height: h)
}()

// MARK: - Math

func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(v, lo), hi) }
func smooth(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
func easeInOut(_ x: Double) -> Double { let t = clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
/// A slightly bouncy spring over seconds (settles in ~0.55 s, ~10% overshoot).
func spring(_ tau: Double) -> Double { tau <= 0 ? 0 : (tau > 1.2 ? 1 : 1 - exp(-tau * 9.5) * cos(tau * 13.5)) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
/// 0→1→0 envelope: fades in at `a`, out at `b`.
func envelope(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.35) -> Double {
    min(smooth((t - a) / fade), smooth((b - t) / fade))
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Timeline

/// Cursor keyframes: the cursor travels from each key to the next (equal points = hold).
let cursorKeys: [(Double, CGPoint)] = [
    (0, CGPoint(x: 1060, y: 640)), (3.8, CGPoint(x: 1060, y: 640)),
    (4.7, CGPoint(x: 756, y: 20)), (5.9, CGPoint(x: 756, y: 20)),
    (6.8, CGPoint(x: 872, y: 120)), (7.0, CGPoint(x: 872, y: 120)),
    (7.8, CGPoint(x: 915, y: 120)), (7.95, CGPoint(x: 915, y: 120)),
    (8.6, CGPoint(x: 724, y: 120)), (10.5, CGPoint(x: 724, y: 120)),
    (11.3, CGPoint(x: 990, y: 430)), (15.9, CGPoint(x: 990, y: 430)),
    (16.7, CGPoint(x: 756, y: 62)), (17.9, CGPoint(x: 756, y: 62)),
    (18.9, CGPoint(x: 906, y: 172)), (20.3, CGPoint(x: 906, y: 172)),
    (21.0, CGPoint(x: 1000, y: 470)), (27.6, CGPoint(x: 1000, y: 470)),
    (28.5, CGPoint(x: 756, y: 20)), (32.6, CGPoint(x: 756, y: 20)),
    (33.4, CGPoint(x: 639, y: 16)), (33.7, CGPoint(x: 639, y: 16)),
    (34.5, CGPoint(x: 836, y: 100)), (36.4, CGPoint(x: 836, y: 100)),
    (37.4, CGPoint(x: 1000, y: 470)), (46.2, CGPoint(x: 1000, y: 470)),
    (47.4, CGPoint(x: 1300, y: 560)), (47.7, CGPoint(x: 1300, y: 560)),
    (49.0, CGPoint(x: 756, y: 44)), (49.4, CGPoint(x: 756, y: 44)),
    (50.3, CGPoint(x: 608, y: 128)), (50.8, CGPoint(x: 608, y: 128)),
    (51.6, CGPoint(x: 1000, y: 540)), (52.6, CGPoint(x: 1000, y: 540)),
    (53.9, CGPoint(x: 840, y: 369)), (54.2, CGPoint(x: 840, y: 369)),
    (55.4, CGPoint(x: 840, y: 471)), (55.7, CGPoint(x: 840, y: 471)),
    (56.8, CGPoint(x: 840, y: 505)), (57.1, CGPoint(x: 840, y: 505)),
    (58.2, CGPoint(x: 840, y: 437)), (58.5, CGPoint(x: 840, y: 437)),
    (59.5, CGPoint(x: 840, y: 335)), (60.2, CGPoint(x: 840, y: 335)),
    (61.4, CGPoint(x: 1100, y: 700)), (duration, CGPoint(x: 1100, y: 700)),
]

let clicks: [Double] = [6.92, 7.9, 8.75, 9.6, 16.85, 19.15, 33.55, 34.65, 47.6, 49.25, 50.45, 54.05, 55.55, 56.95, 58.35, 59.65]
/// Times the mouse button is held down (drags).
let drags: [(Double, Double)] = [(6.92, 7.9), (47.6, 49.25)]

/// Camera keyframes: (time, center in screen points, zoom).
let cameraKeys: [(Double, CGPoint, CGFloat)] = [
    (0, CGPoint(x: 756, y: 491), 1.0), (3.9, CGPoint(x: 756, y: 491), 1.0),
    (5.0, CGPoint(x: 756, y: 150), 2.25), (10.7, CGPoint(x: 756, y: 150), 2.25),
    (11.7, CGPoint(x: 756, y: 200), 1.7), (13.2, CGPoint(x: 756, y: 200), 1.7),
    (14.2, CGPoint(x: 600, y: 340), 1.18), (15.4, CGPoint(x: 600, y: 340), 1.18),
    (16.2, CGPoint(x: 756, y: 175), 2.15), (19.9, CGPoint(x: 756, y: 175), 2.15),
    (20.8, CGPoint(x: 640, y: 300), 1.32), (21.7, CGPoint(x: 640, y: 300), 1.32),
    (22.4, CGPoint(x: 756, y: 150), 2.25), (46.3, CGPoint(x: 756, y: 150), 2.25),
    (47.3, CGPoint(x: 960, y: 420), 1.08), (48.2, CGPoint(x: 960, y: 420), 1.08),
    (49.3, CGPoint(x: 756, y: 170), 1.95), (51.6, CGPoint(x: 756, y: 170), 1.95),
    (52.6, CGPoint(x: 756, y: 316), 1.5), (60.4, CGPoint(x: 756, y: 316), 1.5),
    (61.6, CGPoint(x: 756, y: 491), 1.0), (duration, CGPoint(x: 756, y: 491), 1.0),
]

enum IK: Equatable {
    case collapsed, compactMusic, expandedMusic, compactAgents, alertPermission, expandedApproval, expandedAgents
    case alertCodexDone, alertCharging, expandedBattery, expandedFocusIdle, expandedFocusRunning, alertFocusDone
    case alertCalendar, alertVolume, expandedShelfDrop, expandedShelfFile, compactShelf

    var size: CGSize {
        switch self {
        case .collapsed: CGSize(width: notchW + 16 + 12, height: notchH + 4)
        case .compactMusic: CGSize(width: notchW + 104 + 12, height: notchH + 4)
        case .compactAgents, .compactShelf: CGSize(width: notchW + 136 + 12, height: notchH + 4)
        case .alertPermission, .alertCodexDone, .alertCharging, .alertFocusDone, .alertCalendar, .alertVolume:
            CGSize(width: 360, height: notchH + 56)
        case .expandedApproval: CGSize(width: 400, height: notchH + 250)
        default: CGSize(width: 400, height: notchH + 120)
        }
    }

    var radius: CGFloat {
        switch self {
        case .collapsed: 10
        case .compactMusic, .compactAgents, .compactShelf: 13
        default: 26
        }
    }
}

let islandKeys: [(Double, IK)] = [
    (0, .collapsed), (4.95, .expandedMusic), (11.2, .compactMusic), (13.6, .compactAgents),
    (15.5, .alertPermission), (16.95, .expandedApproval), (19.25, .expandedAgents), (20.9, .compactAgents),
    (22.0, .alertCodexDone), (24.6, .compactAgents), (25.6, .alertCharging), (28.3, .compactAgents),
    (28.7, .expandedBattery), (33.6, .expandedFocusIdle), (34.7, .expandedFocusRunning), (38.9, .alertFocusDone),
    (41.2, .alertCalendar), (43.9, .alertVolume), (46.2, .collapsed), (48.6, .expandedShelfDrop),
    (49.35, .expandedShelfFile), (51.9, .compactShelf), (52.9, .expandedMusic), (60.6, .collapsed),
]

let captions: [(Double, Double, String)] = [
    (4.0, 6.9, "Hover the notch. It opens."),
    (7.0, 10.6, "Music controls and volume, right in the notch"),
    (11.2, 13.4, "Then it folds into a live activity"),
    (13.6, 16.5, "Every Claude Code and Codex session, live"),
    (16.8, 20.6, "Approve or deny from the island. Never automatic."),
    (21.8, 24.8, "Alerts when an agent finishes or needs you"),
    (25.6, 28.4, "Plug in and watch it charge"),
    (28.7, 33.4, "Live battery stats: power, health, cycles"),
    (33.6, 38.8, "A focus timer with a draining ring"),
    (41.2, 46.0, "Meetings, volume and brightness, in the notch"),
    (46.6, 51.8, "Drop files on the notch to hold them"),
    (52.6, 60.4, "Themes: materials, colors, fonts and motion"),
]

let keyPresses: [Double] = [44.0, 44.5, 45.0]

// MARK: - Themes

struct DTheme {
    var name: String
    var fill: AnyShapeStyle
    var fg: Color
    var sec: Color
    var accent: Color
    var border: Color
    var borderWidth: CGFloat
    var glow: Color?
    var design: Font.Design

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: design) }
}

let themes: [DTheme] = [
    DTheme(name: "Stealth", fill: AnyShapeStyle(Color.black), fg: .white, sec: .white.opacity(0.6), accent: Color(hex: 0x0A84FF),
           border: .clear, borderWidth: 0, glow: nil, design: .default),
    DTheme(name: "Glass", fill: AnyShapeStyle(Color(hex: 0x2A2B33, alpha: 0.86)), fg: .white, sec: .white.opacity(0.62),
           accent: Color(hex: 0x0A84FF), border: .white.opacity(0.28), borderWidth: 0.8, glow: .black.opacity(0.45), design: .default),
    DTheme(name: "Wallpaper Match", fill: AnyShapeStyle(Color(hex: 0x231A33, alpha: 0.9)), fg: .white, sec: .white.opacity(0.62),
           accent: Color(hex: 0xF0A35E), border: .white.opacity(0.2), borderWidth: 1, glow: .black.opacity(0.4), design: .default),
    DTheme(name: "Graphite Minimal", fill: AnyShapeStyle(Color(hex: 0x1C1C1E)), fg: Color(hex: 0xE5E5EA), sec: Color(hex: 0x8E8E93),
           accent: Color(hex: 0xAEAEB2), border: Color(hex: 0x3A3A3C), borderWidth: 1, glow: .black.opacity(0.4), design: .default),
    DTheme(name: "Neon Terminal", fill: AnyShapeStyle(Color.black), fg: Color(hex: 0x39FF14), sec: Color(hex: 0x1FAA0D),
           accent: Color(hex: 0x39FF14), border: Color(hex: 0x39FF14, alpha: 0.6), borderWidth: 1, glow: Color(hex: 0x39FF14, alpha: 0.55),
           design: .monospaced),
    DTheme(name: "Pastel Rounded", fill: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3A2D45), Color(hex: 0x241E2C)],
                                                                         startPoint: .topLeading, endPoint: .bottomTrailing)),
           fg: Color(hex: 0xF8ECF4), sec: Color(hex: 0xD7C2D8), accent: Color(hex: 0xFFB3C7), border: .white.opacity(0.14),
           borderWidth: 1, glow: .black.opacity(0.4), design: .rounded),
]

/// Settings list order → theme index.
let settingsOrder = [0, 1, 2, 3, 4, 5]
let themeKeys: [(Double, Int)] = [(0, 0), (54.1, 1), (55.6, 4), (57.0, 5), (58.4, 3), (59.7, 0)]

// MARK: - Timeline queries

func cursorPosition(_ t: Double) -> CGPoint {
    guard let i = cursorKeys.lastIndex(where: { $0.0 <= t }) else { return cursorKeys[0].1 }
    guard i < cursorKeys.count - 1 else { return cursorKeys[i].1 }
    let (t0, p0) = cursorKeys[i], (t1, p1) = cursorKeys[i + 1]
    if p0 == p1 { return p0 }
    let dragging = drags.contains { t0 >= $0.0 && t1 <= $0.1 + 0.01 }
    let u = dragging ? smooth((t - t0) / (t1 - t0)) : easeInOut((t - t0) / (t1 - t0))
    // A gentle arc, like a real hand.
    let dx = p1.x - p0.x, dy = p1.y - p0.y
    let len = max(1, sqrt(dx * dx + dy * dy))
    let bend = min(len * 0.1, 50) * (dragging ? 0.4 : 1)
    let mid = CGPoint(x: (p0.x + p1.x) / 2 - dy / len * bend, y: (p0.y + p1.y) / 2 + dx / len * bend)
    let a = lerp(p0, mid, u), b = lerp(mid, p1, u)
    return lerp(a, b, u)
}

func camera(_ t: Double) -> (center: CGPoint, zoom: CGFloat) {
    guard let i = cameraKeys.lastIndex(where: { $0.0 <= t }) else { return (cameraKeys[0].1, cameraKeys[0].2) }
    guard i < cameraKeys.count - 1 else { return (cameraKeys[i].1, cameraKeys[i].2) }
    let (t0, c0, z0) = cameraKeys[i], (t1, c1, z1) = cameraKeys[i + 1]
    let u = easeInOut((t - t0) / (t1 - t0))
    return (lerp(c0, c1, u), lerp(z0, z1, u))
}

func islandIndex(_ t: Double) -> Int { islandKeys.lastIndex { $0.0 <= t } ?? 0 }

func theme(_ t: Double) -> (current: DTheme, previous: DTheme, blend: Double) {
    let i = themeKeys.lastIndex { $0.0 <= t } ?? 0
    let prev = i > 0 ? themeKeys[i - 1].1 : themeKeys[i].1
    return (themes[themeKeys[i].1], themes[prev], smooth((t - themeKeys[i].0) / 0.35))
}

func isPlaying(_ t: Double) -> Bool { !(t >= 8.75 && t < 9.6) }

func volume(_ t: Double) -> Double {
    if t < 6.92 { return 0.55 }
    if t < 7.9 { return clamp(Double((cursorPosition(t).x - 794) / 142)) }
    return 0.85
}

func hudVolume(_ t: Double) -> Double {
    let steps = keyPresses.filter { t >= $0 }.count
    return 0.5 + Double(steps) * 0.0625
}

func focusRemaining(_ t: Double) -> Double {
    if t < 34.7 { return 1500 }
    return 1500 * (1 - easeInOut((t - 35.0) / 3.6))
}

// MARK: - Shapes

struct NotchShape: Shape {
    var topCurve: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topCurve, rect.width / 4, rect.height / 2))
        let minX = rect.minX + top, maxX = rect.maxX - top
        let bottom = max(0, min(bottomRadius, (maxX - minX) / 2, rect.height - top))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: minX, y: rect.minY + top), control: CGPoint(x: minX, y: rect.minY))
        p.addLine(to: CGPoint(x: minX, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: minX + bottom, y: rect.maxY), control: CGPoint(x: minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: maxX - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: maxX, y: rect.maxY - bottom), control: CGPoint(x: maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: maxX, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Places a view with its leading edge (or center) at a point, in a parent's coordinates.
extension View {
    /// `x` is the leading edge for `.leading`, the trailing edge for `.trailing`, the center otherwise.
    func at(_ x: CGFloat, _ y: CGFloat, width: CGFloat? = nil, align: Alignment = .leading) -> some View {
        let w = width ?? 1000
        let centerX = align == .leading ? x + w / 2 : (align == .trailing ? x - w / 2 : x)
        return self.fixedSize(horizontal: width == nil, vertical: true)
            .frame(width: w, alignment: align)
            .position(x: centerX, y: y)
    }
}

// MARK: - Island content

/// A minimal record-sleeve cover: off-white, one black disc, a hairline, small type.
struct AlbumArt: View {
    var size: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0xECE9E3)
            Circle().fill(Color(hex: 0x111111)).frame(width: size * 0.62, height: size * 0.62)
                .offset(x: size * 0.3, y: size * 0.12)
            Rectangle().fill(Color(hex: 0x111111)).frame(width: size * 0.5, height: max(0.6, size * 0.012))
                .offset(x: size * 0.1, y: size * 0.8)
            Text("MIDNIGHT DRIVE").font(.system(size: size * 0.075, weight: .bold)).tracking(size * 0.008)
                .foregroundStyle(Color(hex: 0x111111)).offset(x: size * 0.1, y: size * 0.84)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

struct Waveform: View {
    var t: Double
    var playing: Bool
    var color: Color
    var body: some View {
        HStack(spacing: 2.6) {
            ForEach(0..<4, id: \.self) { i in
                let h = playing ? 0.3 + 0.7 * abs(sin(t * (5.2 + Double(i) * 1.7) + Double(i) * 1.3)) : 0.3
                Capsule().fill(color).frame(width: 3.2, height: 14 * h)
            }
        }
        .frame(width: 22, height: 14)
    }
}

struct ProviderIcon: View {
    var codex: Bool
    var size: CGFloat
    var body: some View {
        Image(systemName: codex ? "chevron.left.forwardslash.chevron.right" : "asterisk")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(codex ? Color(hex: 0x10A37F) : Color(hex: 0xD97757))
    }
}

/// The tab strip in the expanded island (left of the notch: agents, music, timer;
/// right: battery, shelf, settings), exactly as the app distributes them.
struct TabStrip: View {
    var selected: Int
    var th: DTheme
    var body: some View {
        let symbols = ["sparkles", "music.note", "timer", "battery.75percent", "tray.full"]
        let xs: [CGFloat] = [31, 57, 83, 317, 343]
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: symbols[i])
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(i == selected ? th.fg : th.sec)
                    .frame(width: 22, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6).fill(th.fg.opacity(i == selected ? 0.16 : 0)))
                    .position(x: xs[i], y: 16)
            }
            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(th.sec).position(x: 369, y: 16)
        }
    }
}

struct IslandContent: View {
    let kind: IK
    let t: Double
    let local: Double
    let th: DTheme

    var body: some View {
        let size = kind.size
        ZStack(alignment: .topLeading) {
            content
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder var content: some View {
        switch kind {
        case .collapsed:
            Color.clear
        case .compactMusic:
            Circle().fill(th.sec).frame(width: 4, height: 4).position(x: 17, y: 18)
            AlbumArt(size: 30).position(x: 40, y: 18)
            Waveform(t: t, playing: isPlaying(t), color: .white.opacity(0.9)).position(x: 270, y: 18)
        case .compactAgents:
            HStack(spacing: 5) {
                ProviderIcon(codex: false, size: 11)
                Circle().fill(Color(hex: 0xD97757)).frame(width: 7, height: 7).opacity(0.4 + 0.6 * abs(sin(t * 3)))
            }.at(20, 18)
            HStack(spacing: 5) {
                Text("notch-app").font(th.font(10.5, .semibold)).foregroundStyle(th.fg)
                Text("2").font(th.font(9.5, .bold)).padding(.horizontal, 4).background(Capsule().fill(th.fg.opacity(0.22))).foregroundStyle(th.fg)
            }.at(320, 18, width: 120, align: .trailing)
        case .compactShelf:
            Image(systemName: "tray.full.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(th.fg).position(x: 30, y: 18)
            Text("1").font(th.font(12, .semibold)).foregroundStyle(th.fg).position(x: 312, y: 18)
        case .expandedMusic:
            expandedMusic
        case .alertPermission:
            alertRow(icon: AnyView(Image(systemName: "hand.raised.fill").font(.system(size: 17)).foregroundStyle(.orange)),
                     title: "Claude Code wants to use Bash", subtitle: "notch-app · click to review",
                     trailing: AnyView(ProviderIcon(codex: false, size: 15)))
        case .alertCodexDone:
            alertRow(icon: AnyView(ProviderIcon(codex: true, size: 16)), title: "Codex · api-server",
                     subtitle: "Fixed the flaky test. All 214 tests pass.",
                     trailing: AnyView(Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green)))
        case .alertCharging:
            let level = 0.6 + 0.04 * smooth(local / 1.2)
            alertRow(icon: AnyView(MiniBattery(level: level, charging: true, t: t, th: th).frame(width: 40, height: 19)),
                     title: "Charging", subtitle: "Power adapter connected",
                     trailing: AnyView(Text("\(Int(level * 100))%").font(th.font(15, .bold)).monospacedDigit().foregroundStyle(.green)))
        case .alertFocusDone:
            alertRow(icon: AnyView(Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(.green)),
                     title: "Focus session done", subtitle: "1 today. Take a short break.", trailing: AnyView(EmptyView()))
        case .alertCalendar:
            alertRow(icon: AnyView(Image(systemName: "calendar").font(.system(size: 17)).foregroundStyle(.orange)),
                     title: "Design review", subtitle: "in 5m · Zoom",
                     trailing: AnyView(Text("Join").font(th.font(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 4).background(Capsule().fill(th.accent))))
        case .alertVolume:
            let level = hudVolume(t)
            HStack(spacing: 12) {
                Image(systemName: level > 0.6 ? "speaker.wave.3.fill" : "speaker.wave.2.fill").font(.system(size: 16)).foregroundStyle(th.fg)
                    .frame(width: 24)
                ZStack(alignment: .leading) {
                    Capsule().fill(th.fg.opacity(0.18))
                    Capsule().fill(th.fg).frame(width: 220 * level)
                }.frame(width: 220, height: 6)
                Text("\(Int(level * 100))").font(th.font(11, .medium)).monospacedDigit().foregroundStyle(th.sec).frame(width: 26, alignment: .trailing)
            }
            .at(180, 60, align: .center)
        case .expandedApproval:
            TabStrip(selected: 0, th: th)
            approvalCard
            sessionRow(y: 236, codex: true, project: "api-server", branch: "main", state: "Thinking", stateColor: th.sec, message: "Looking at the flaky test")
        case .expandedAgents:
            TabStrip(selected: 0, th: th)
            Text("2 sessions").font(th.font(10.5)).foregroundStyle(th.sec).at(20, 46)
            sessionRow(y: 78, codex: false, project: "notch-app", branch: "feature/dark-mode", state: "Running Bash · npm run build",
                       stateColor: th.sec, message: "Approved from the island")
            sessionRow(y: 124, codex: true, project: "api-server", branch: "main", state: "Thinking", stateColor: th.sec,
                       message: "Looking at the flaky test")
        case .expandedBattery:
            TabStrip(selected: 3, th: th)
            BigBattery(level: 0.64, t: t, local: local, th: th).frame(width: 104, height: 50).position(x: 72, y: 88)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("64%").font(th.font(30, .bold)).monospacedDigit().foregroundStyle(th.fg)
                Text("48m until full").font(th.font(10.5)).foregroundStyle(.green)
            }.at(142, 64)
            HStack(spacing: 5) {
                chip("bolt.fill", "Charging 38.5 W", tint: .green)
                chip("powerplug.fill", "96 W adapter", tint: nil)
            }.at(142, 96)
            HStack(spacing: 5) {
                chip("heart.fill", "94% health", tint: nil)
                chip("arrow.triangle.2.circlepath", "212 cycles", tint: nil)
            }.at(142, 120)
        case .expandedFocusIdle, .expandedFocusRunning:
            focusPage(running: kind == .expandedFocusRunning)
        case .expandedShelfDrop, .expandedShelfFile:
            TabStrip(selected: 4, th: th)
            if kind == .expandedShelfDrop {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(th.accent, style: StrokeStyle(lineWidth: 1.6, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(th.accent.opacity(0.12)))
                    .frame(width: 360, height: 96).position(x: 200, y: 88)
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 20))
                    Text("Drop to hold it here").font(th.font(12, .medium))
                }.foregroundStyle(th.accent).position(x: 200, y: 88)
            } else {
                VStack(spacing: 3) {
                    DocIcon(size: 40)
                    Text("Design-spec.pdf").font(th.font(10)).foregroundStyle(th.fg).lineLimit(1)
                }.position(x: 62, y: 78)
                HStack(spacing: 16) {
                    Label("AirDrop", systemImage: "airplayaudio")
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(th.fg.opacity(t > 50.45 && t < 51.0 ? 0.25 : 0)))
                    Label("Show in Finder", systemImage: "folder")
                }
                .font(th.font(10.5)).foregroundStyle(th.sec).at(20, 128)
                Label("Clear", systemImage: "xmark.circle").font(th.font(10.5)).foregroundStyle(th.sec).at(380, 128, width: 80, align: .trailing)
            }
        }
    }

    // MARK: Pieces

    var expandedMusic: some View {
        ZStack(alignment: .topLeading) {
            TabStrip(selected: 1, th: th)
            AlbumArt(size: 92).shadow(color: .black.opacity(0.35), radius: 6, y: 2).position(x: 66, y: 88)
            Text("Midnight Drive").font(th.font(13, .semibold)).foregroundStyle(th.fg).at(124, 50)
            Text("The Placeholders — Demo Tapes").font(th.font(10.5)).foregroundStyle(th.sec).at(124, 67)
            RoundedRectangle(cornerRadius: 3.5).fill(th.fg.opacity(0.16))
                .frame(width: 16, height: 16).overlay(Image(systemName: "music.note").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                .position(x: 372, y: 52)
            let elapsed = 83 + (isPlaying(t) ? max(0, t - 4.95) : 0)
            Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)).font(th.font(10, .medium)).monospacedDigit()
                .foregroundStyle(th.sec).at(124, 92)
            ZStack(alignment: .leading) {
                Capsule().fill(th.fg.opacity(0.18))
                Capsule().fill(th.fg.opacity(0.9)).frame(width: 188 * elapsed / 214)
            }.frame(width: 188, height: 4).position(x: 252, y: 92)
            Text(String(format: "-%d:%02d", Int(214 - elapsed) / 60, Int(214 - elapsed) % 60)).font(th.font(10, .medium)).monospacedDigit()
                .foregroundStyle(th.sec).at(380, 92, width: 40, align: .trailing)
            Image(systemName: "backward.fill").font(.system(size: 14)).foregroundStyle(th.fg).position(x: 138, y: 120)
            Image(systemName: isPlaying(t) ? "pause.fill" : "play.fill").font(.system(size: 19)).foregroundStyle(th.fg).position(x: 168, y: 120)
            Image(systemName: "forward.fill").font(.system(size: 14)).foregroundStyle(th.fg).position(x: 198, y: 120)
            Image(systemName: volume(t) > 0.66 ? "speaker.wave.3.fill" : "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(th.sec).position(x: 228, y: 120)
            let pressing = t > 6.92 && t < 7.9
            ZStack(alignment: .leading) {
                Capsule().fill(th.fg.opacity(0.18))
                Capsule().fill(th.fg.opacity(0.85)).frame(width: 142 * volume(t))
            }.frame(width: 142, height: pressing ? 6 : 4).position(x: 238 + 71, y: 120)
        }
    }

    var approvalCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.75), lineWidth: 1)
                .frame(width: 360, height: 156).position(x: 200, y: 118)
            HStack(spacing: 6) {
                ProviderIcon(codex: false, size: 12)
                Text("Claude Code wants to use Bash").font(th.font(12, .semibold)).foregroundStyle(th.fg)
            }.at(30, 56)
            Text("\(max(0, 45 - Int(local)))s").font(th.font(10, .medium)).monospacedDigit().foregroundStyle(th.sec).at(370, 56, width: 30, align: .trailing)
            Text("notch-app").font(th.font(10.5)).foregroundStyle(th.sec).at(30, 74)
            RoundedRectangle(cornerRadius: 6).fill(th.fg.opacity(0.08)).frame(width: 336, height: 56).position(x: 200, y: 114)
            VStack(alignment: .leading, spacing: 2) {
                Text("{").foregroundStyle(th.sec)
                (Text("  \"command\"").foregroundColor(Color(hex: 0x9CDCFE)) + Text(" : ").foregroundColor(th.sec) + Text("\"npm run build\"").foregroundColor(Color(hex: 0xCE9178)))
                Text("}").foregroundStyle(th.sec)
            }.font(.system(size: 10.5, design: .monospaced)).at(40, 114)
            Text("If you don't decide, it asks in the terminal.").font(.system(size: 9)).foregroundStyle(th.sec).at(30, 172)
            Text("Deny").font(th.font(10.5, .semibold)).foregroundStyle(.white).frame(width: 54, height: 22)
                .background(Capsule().fill(Color.red.opacity(0.85))).position(x: 290, y: 172)
            Text("Allow").font(th.font(10.5, .semibold)).foregroundStyle(.white).frame(width: 54, height: 22)
                .background(Capsule().fill(Color.green.opacity(t > 19.15 ? 1 : 0.85))).position(x: 350, y: 172)
        }
    }

    func sessionRow(y: CGFloat, codex: Bool, project: String, branch: String, state: String, stateColor: Color, message: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(th.fg.opacity(0.06)).frame(width: 360, height: 42).position(x: 200, y: y)
            Circle().fill((codex ? Color(hex: 0x10A37F) : Color(hex: 0xD97757)).opacity(0.2)).frame(width: 24, height: 24).position(x: 40, y: y - 6)
            ProviderIcon(codex: codex, size: 11).position(x: 40, y: y - 6)
            HStack(spacing: 5) {
                Text(project).font(th.font(11.5, .semibold)).foregroundStyle(th.fg)
                Text(branch).font(th.font(10)).foregroundStyle(th.sec)
            }.at(60, y - 12)
            Text(String(format: "%d:%02d", Int(t * 1.0 + (codex ? 300 : 740)) / 60 % 60, Int(t + (codex ? 300 : 740)) % 60))
                .font(th.font(10, .medium)).monospacedDigit().foregroundStyle(th.sec).at(370, y - 12, width: 40, align: .trailing)
            HStack(spacing: 4) {
                Circle().fill(codex ? Color(hex: 0x10A37F) : Color(hex: 0xD97757)).frame(width: 6, height: 6).opacity(0.45 + 0.55 * abs(sin(t * 3)))
                Text("\(state) · \(message)").font(th.font(10)).foregroundStyle(stateColor).lineLimit(1)
            }.at(60, y + 6, width: 300)
        }
    }

    func focusPage(running: Bool) -> some View {
        let remaining = focusRemaining(t)
        let text = String(format: "%d:%02d", Int(remaining.rounded(.up)) / 60, Int(remaining.rounded(.up)) % 60)
        return ZStack(alignment: .topLeading) {
            TabStrip(selected: 2, th: th)
            Circle().stroke(th.accent.opacity(0.18), lineWidth: 6).frame(width: 78, height: 78).position(x: 63, y: 88)
            if running {
                Circle().stroke(th.accent.opacity(0.18 + 0.25 * abs(sin(t * 1.4))), lineWidth: 13).frame(width: 78, height: 78)
                    .blur(radius: 4).position(x: 63, y: 88)
            }
            Circle().trim(from: 0, to: remaining / 1500).stroke(th.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 78, height: 78).position(x: 63, y: 88)
            if running {
                Text(text).font(th.font(17, .bold)).monospacedDigit().foregroundStyle(th.fg).position(x: 63, y: 88)
            } else {
                Image(systemName: "timer").font(.system(size: 22)).foregroundStyle(th.accent).position(x: 63, y: 88)
            }
            Text(running ? "Focusing" : "Ready to focus").font(th.font(13, .semibold)).foregroundStyle(th.fg).at(122, 50)
            Text(running ? "Ends at 10:25 PM" : "Pick a length and start").font(th.font(10.5)).foregroundStyle(th.sec).at(122, 66)
            if running {
                HStack(spacing: 8) {
                    pill("pause.fill", "Pause", prominent: false)
                    pill("plus", "5 min", prominent: false)
                    pill("stop.fill", "Stop", prominent: false)
                }.at(122, 96)
            } else {
                HStack(spacing: 6) {
                    ForEach(["15m", "25m", "50m"], id: \.self) { m in
                        Text(m).font(th.font(10.5, .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(m == "25m" ? th.accent.opacity(0.9) : th.fg.opacity(0.1)))
                            .foregroundStyle(m == "25m" ? Color.white : th.fg)
                    }
                    pill("play.fill", "Start", prominent: true)
                }.at(122, 96)
            }
            Text("No sessions yet today").font(th.font(10.5)).foregroundStyle(th.sec).at(122, 124)
        }
    }

    func pill(_ symbol: String, _ text: String, prominent: Bool) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon).font(th.font(10.5, .semibold))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(prominent ? th.accent.opacity(0.9) : th.fg.opacity(0.1)))
            .foregroundStyle(prominent ? Color.white : th.fg)
    }

    func chip(_ symbol: String, _ text: String, tint: Color?) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon).font(th.font(10.5, .medium)).monospacedDigit()
            .foregroundStyle(tint ?? th.fg.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((tint ?? th.fg).opacity(0.12)))
    }

    func alertRow(icon: AnyView, title: String, subtitle: String, trailing: AnyView) -> some View {
        HStack(spacing: 11) {
            icon.frame(width: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(th.font(13, .semibold)).foregroundStyle(th.fg).lineLimit(1)
                Text(subtitle).font(th.font(10.5)).foregroundStyle(th.sec).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .frame(width: 320)
        .position(x: 180, y: 60)
    }
}

struct MiniBattery: View {
    var level: Double
    var charging: Bool
    var t: Double
    var th: DTheme
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: g.size.height * 0.28).stroke(th.fg.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: g.size.height * 0.18).fill(Color.green)
                        .frame(width: max(2, (g.size.width - 8) * level)).padding(2)
                    Image(systemName: "bolt.fill").font(.system(size: g.size.height * 0.62, weight: .heavy)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1).frame(maxWidth: .infinity)
                }
                RoundedRectangle(cornerRadius: 1).fill(th.fg.opacity(0.45)).frame(width: 2.5, height: g.size.height * 0.4)
            }
        }
    }
}

struct BigBattery: View {
    var level: Double
    var t: Double
    var local: Double
    var th: DTheme
    var body: some View {
        let sweep = 0.1 + (level - 0.1) * (1 - pow(1 - clamp(local / 0.9), 3))
        GeometryReader { g in
            let h = g.size.height
            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: h * 0.24, style: .continuous).stroke(th.fg.opacity(0.4), lineWidth: 1.5)
                    let fillWidth = (g.size.width - 14) * sweep
                    ZStack(alignment: .leading) {
                        Color.green
                        // Shimmer travelling across while charging.
                        let phase = (t * 0.55).truncatingRemainder(dividingBy: 1)
                        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: fillWidth * 0.45)
                            .offset(x: CGFloat(-0.3 + phase * 1.6) * fillWidth)
                    }
                    .frame(width: fillWidth, height: h - 8)
                    .clipShape(RoundedRectangle(cornerRadius: h * 0.16))
                    .padding(4)
                    Image(systemName: "bolt.fill").font(.system(size: h * 0.46, weight: .heavy)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2).frame(maxWidth: .infinity)
                }
                RoundedRectangle(cornerRadius: 2).fill(th.fg.opacity(0.4)).frame(width: 5, height: h * 0.36)
            }
        }
    }
}

struct DocIcon: View {
    var size: CGFloat
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.08).fill(.white).frame(width: size * 0.78, height: size)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: size * 0.22, y: size * 0.22)); p.addLine(to: CGPoint(x: 0, y: size * 0.22)); p.closeSubpath()
            }.fill(Color(hex: 0xD9D9DE)).frame(width: size * 0.22, height: size * 0.22)
            Text("PDF").font(.system(size: size * 0.2, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, size * 0.05).background(RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x3A3A3C)))
                .offset(x: -size * 0.18, y: size * 0.62)
        }
        .frame(width: size * 0.78, height: size)
    }
}

// MARK: - The island (shape morph + content crossfade)

struct Island: View {
    let t: Double

    var body: some View {
        let i = islandIndex(t)
        let (t0, cur) = islandKeys[i]
        let prev = i > 0 ? islandKeys[i - 1].1 : cur
        let tau = t - t0
        let p = spring(tau)
        let size = CGSize(width: lerp(prev.size.width, cur.size.width, p), height: lerp(prev.size.height, cur.size.height, p))
        let radius = lerp(prev.radius, cur.radius, clamp(p))
        let shape = NotchShape(topCurve: 6, bottomRadius: radius)
        let th = theme(t)
        let collapsedish = cur == .collapsed && tau > 0.3
        ZStack {
            layer(th.previous, shape: shape, size: size, cur: cur, prev: prev, tau: tau, t0: t0, plain: collapsedish).opacity(1 - th.blend)
            layer(th.current, shape: shape, size: size, cur: cur, prev: prev, tau: tau, t0: t0, plain: collapsedish).opacity(th.blend)
        }
        .frame(width: size.width, height: size.height)
    }

    func layer(_ th: DTheme, shape: NotchShape, size: CGSize, cur: IK, prev: IK, tau: Double, t0: Double, plain: Bool) -> some View {
        let prevT0 = islandIndex(t) > 0 ? islandKeys[islandIndex(t) - 1].0 : t0
        return ZStack(alignment: .top) {
            shape.fill(plain ? AnyShapeStyle(Color.black) : th.fill)
            ZStack(alignment: .top) {
                if tau < 0.25 && prev != cur {
                    IslandContent(kind: prev, t: t, local: t - prevT0, th: th).opacity(1 - smooth(tau / 0.16))
                }
                IslandContent(kind: cur, t: t, local: tau, th: th)
                    .opacity(prev == cur ? 1 : smooth((tau - 0.08) / 0.22))
                    .scaleEffect(prev == cur ? 1 : 0.94 + 0.06 * smooth(tau / 0.4), anchor: .top)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            if th.borderWidth > 0 && !plain {
                shape.stroke(th.border, lineWidth: th.borderWidth)
            }
        }
        .shadow(color: plain ? .clear : (th.glow ?? .clear), radius: th.glow == nil ? 0 : 14, y: 4)
    }
}

// MARK: - The desktop

/// Graphite dunes: layered silhouettes with crisp highlight edges, lit faintly from above.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1C1E22), Color(hex: 0x0D0E10)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(0.07), .clear], center: UnitPoint(x: 0.3, y: 0.05), startRadius: 0, endRadius: 900)
            dune(0.50, amp: 0.05, freq: 1.3, phase: 0.4, color: 0x2B2E34)
            dune(0.63, amp: 0.06, freq: 1.0, phase: 2.1, color: 0x212328)
            dune(0.76, amp: 0.05, freq: 1.6, phase: 4.0, color: 0x17181C)
            dune(0.88, amp: 0.04, freq: 1.2, phase: 5.3, color: 0x0F1012)
        }
    }

    func dune(_ baseline: CGFloat, amp: CGFloat, freq: CGFloat, phase: CGFloat, color: UInt32) -> some View {
        let shape = Dune(baseline: baseline, amplitude: amp, frequency: freq, phase: phase)
        return ZStack {
            shape.fill(Color(hex: color))
            DuneEdge(baseline: baseline, amplitude: amp, frequency: freq, phase: phase).stroke(.white.opacity(0.07), lineWidth: 1.2)
        }
    }
}

struct Dune: Shape {
    var baseline, amplitude, frequency, phase: CGFloat
    func path(in r: CGRect) -> Path {
        var p = DuneEdge(baseline: baseline, amplitude: amplitude, frequency: frequency, phase: phase).path(in: r)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct DuneEdge: Shape {
    var baseline, amplitude, frequency, phase: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let steps = 120
        for i in 0...steps {
            let x = r.width * CGFloat(i) / CGFloat(steps)
            let u = x / r.width
            let y = r.height * (baseline - amplitude * (sin(u * .pi * 2 * frequency + phase) * 0.7 + sin(u * .pi * 5.3 * frequency + phase * 1.7) * 0.3))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

struct MenuBar: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.26)).frame(height: notchH)
            HStack(spacing: 20) {
                Image(systemName: "apple.logo").font(.system(size: 15))
                Text("Finder").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
                Spacer()
                Image(systemName: "capsule.inset.filled")
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "switch.2")
                Image(systemName: "magnifyingglass")
                Text("Thu Nov 26  9:41 PM")
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: notchH)
        }
        .frame(width: S.width, height: notchH)
    }
}

struct MacWindow<Content: View>: View {
    var title: String
    var size: CGSize
    var dark = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57)).frame(width: 12)
                    Circle().fill(Color(hex: 0xFEBC2E)).frame(width: 12)
                    Circle().fill(Color(hex: 0x28C840)).frame(width: 12)
                    Spacer()
                }
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(dark ? .white.opacity(0.75) : .black.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xEDEDF0))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .background(dark ? Color(hex: 0x1C1C1F) : Color(hex: 0xF7F7F9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 16)
    }
}

struct TerminalWindow: View {
    let t: Double
    var body: some View {
        MacWindow(title: "notch-app — claude — 92×28", size: CGSize(width: 600, height: 400)) {
            VStack(alignment: .leading, spacing: 5) {
                line([("~/code/notch-app ", 0x7FD1B9), ("❯ ", 0xC678DD), ("claude", 0xFFFFFF)])
                line([("✻ ", 0xD97757), ("Welcome back! Working in notch-app", 0xBBBBBB)])
                line([("> ", 0x888888), ("Add a dark mode toggle and make sure the build passes", 0xFFFFFF)])
                line([("● ", 0xFFFFFF), ("I'll add the toggle to Settings and run the build.", 0xDDDDDD)])
                line([("● ", 0x7FD1B9), ("Edit", 0xFFFFFF), ("(src/Settings.swift)", 0x999999)])
                line([("  ⎿  ", 0x777777), ("Updated with 24 additions and 3 removals", 0x999999)])
                if t >= 15.5 {
                    line([("● ", 0xE5C07B), ("Bash", 0xFFFFFF), ("(npm run build)", 0x999999)])
                    if t < 19.15 {
                        line([("  ⎿  ", 0x777777), ("Waiting for permission…", 0xE5A04B)])
                    } else {
                        line([("  ⎿  ", 0x777777), ("Approved from DynamicIsland4Mac", 0x7FD1B9)])
                        if t >= 20.4 { line([("  ⎿  ", 0x777777), ("Build succeeded in 8.2s", 0x98C379)]) }
                    }
                }
                if t >= 20.8 { line([("● ", 0xFFFFFF), ("Done: the toggle is live and the build passes.", 0xDDDDDD)]) }
            }
            .padding(16)
        }
    }

    func line(_ parts: [(String, UInt32)]) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor(Color(hex: $1.1)) }
            .font(.system(size: 12.5, design: .monospaced))
    }
}

struct EditorWindow: View {
    var body: some View {
        MacWindow(title: "SettingsView.swift — notch-app", size: CGSize(width: 620, height: 470)) {
            VStack(alignment: .leading, spacing: 5) {
                code([("struct ", 0xC678DD), ("SettingsView", 0xE5C07B), (": ", 0xABB2BF), ("View", 0x61AFEF), (" {", 0xABB2BF)])
                code([("    @AppStorage", 0xC678DD), ("(\"darkMode\") ", 0x98C379), ("var ", 0xC678DD), ("darkMode = ", 0xABB2BF), ("false", 0xD19A66)])
                code([("", 0)])
                code([("    var ", 0xC678DD), ("body", 0xE06C75), (": some ", 0xABB2BF), ("View", 0x61AFEF), (" {", 0xABB2BF)])
                code([("        Form", 0x61AFEF), (" {", 0xABB2BF)])
                code([("            Toggle", 0x61AFEF), ("(\"Dark mode\", ", 0x98C379), ("isOn: ", 0xABB2BF), ("$darkMode", 0xE06C75), (")", 0xABB2BF)])
                code([("            Picker", 0x61AFEF), ("(\"Accent\", ", 0x98C379), ("selection: ", 0xABB2BF), ("$accent", 0xE06C75), (") {", 0xABB2BF)])
                code([("                ForEach", 0x61AFEF), ("(Accent.", 0xABB2BF), ("allCases", 0xE06C75), (") { ", 0xABB2BF), ("Text", 0x61AFEF), ("($0.", 0xABB2BF), ("name", 0xE06C75), (") }", 0xABB2BF)])
                code([("            }", 0xABB2BF)])
                code([("        }", 0xABB2BF)])
                code([("        .formStyle", 0x61AFEF), ("(.", 0xABB2BF), ("grouped", 0xE06C75), (")", 0xABB2BF)])
                code([("    }", 0xABB2BF)])
                code([("}", 0xABB2BF)])
            }
            .padding(18)
        }
    }

    func code(_ parts: [(String, UInt32)]) -> some View {
        parts.reduce(Text(" ")) { $0 + Text($1.0).foregroundColor(Color(hex: $1.1)) }
            .font(.system(size: 13, design: .monospaced))
    }
}

struct Dock: View {
    var body: some View {
        let symbols = ["face.smiling", "globe", "terminal", "music.note", "calendar", "message.fill", "photo", "gearshape.fill"]
        HStack(spacing: 10) {
            ForEach(symbols, id: \.self) { symbol in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: 0x1E1F23))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.8))
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.88)))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.8))
    }
}

struct SettingsWindow: View {
    let t: Double
    var body: some View {
        let selected = themeKeys.last { $0.0 <= t }?.1 ?? 0
        MacWindow(title: "DynamicIsland4Mac Settings", size: CGSize(width: 640, height: 420)) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array([("paintbrush", "Appearance"), ("cursorarrow.motionlines", "Behavior"), ("square.grid.2x2", "Modules"),
                                   ("sparkles", "Agents"), ("lock.shield", "Permissions"), ("info.circle", "About")].enumerated()), id: \.offset) { i, item in
                        Label(item.1, systemImage: item.0)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(i == 0 ? Color.white.opacity(0.14) : .clear))
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 170)
                .background(Color(hex: 0x232327))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Theme").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.bottom, 10)
                    ForEach(settingsOrder, id: \.self) { i in
                        let th = themes[i]
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5).fill(th.fill).frame(width: 30, height: 18)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(th.borderWidth > 0 ? th.border : .white.opacity(0.2), lineWidth: 1))
                                .overlay(Circle().fill(th.accent).frame(width: 6).offset(x: 8))
                            Text(th.name).font(.system(size: 13, design: th.design)).foregroundStyle(.white)
                            Spacer()
                            if i == selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0x0A84FF)) }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 7).fill(i == selected ? Color(hex: 0x0A84FF, alpha: 0.22) : .clear))
                    }
                    Text("Changes apply live, here and on your notch.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.top, 12)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

struct Cursor: View {
    var pressed: Bool
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 17))
            p.addLine(to: CGPoint(x: 4.2, y: 13))
            p.addLine(to: CGPoint(x: 6.9, y: 19.2))
            p.addLine(to: CGPoint(x: 9.6, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12))
            p.closeSubpath()
        }
        .fill(Color.black)
        .overlay(Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 17))
            p.addLine(to: CGPoint(x: 4.2, y: 13))
            p.addLine(to: CGPoint(x: 6.9, y: 19.2))
            p.addLine(to: CGPoint(x: 9.6, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12))
            p.closeSubpath()
        }.stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round)))
        .frame(width: 13, height: 20, alignment: .topLeading)
        .scaleEffect(pressed ? 0.86 : 1, anchor: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 2, x: 0.5, y: 1.5)
    }
}

/// The whole MacBook screen at time `t`, in screen points.
struct Screen: View {
    let t: Double

    var body: some View {
        let cursor = cursorPosition(t)
        let pressed = clicks.contains { t >= $0 && t < $0 + 0.14 } || drags.contains { t >= $0.0 && t < $0.1 }
        let settingsOpacity = envelope(t, 52.4, 60.9, fade: 0.4)
        ZStack(alignment: .topLeading) {
            Wallpaper().frame(width: S.width, height: S.height)
            // Desktop file (for the shelf).
            VStack(spacing: 4) {
                DocIcon(size: 46)
                Text("Design-spec.pdf").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x0A84FF, alpha: t > 47.6 && t < 49.3 ? 0.9 : 0)))
            }
            .position(x: 1300, y: 572)
            EditorWindow().position(x: 1110, y: 420)
            TerminalWindow(t: t).position(x: 400, y: 380)
            Dock().position(x: S.width / 2, y: S.height - 44)
            MenuBar().position(x: S.width / 2, y: notchH / 2)
            // The hardware notch, then the island over it.
            NotchShape(topCurve: 4, bottomRadius: 9).fill(Color.black).frame(width: notchW + 8, height: notchH).position(x: cx, y: notchH / 2)
            SettingsWindow(t: t)
                .scaleEffect(0.96 + 0.04 * settingsOpacity)
                .opacity(settingsOpacity)
                .position(x: 756, y: 420)
            Island(t: t).position(x: cx, y: islandHeight(t) / 2)
            if t > 35.0 && t < 38.8 {
                Label("25 minutes in 4 seconds", systemImage: "forward.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .opacity(envelope(t, 35.0, 38.8, fade: 0.25))
                    .position(x: cx, y: 178)
            }
            // Dragged file ghost.
            if t > 47.6 && t < 49.3 {
                DocIcon(size: 46).opacity(0.85).scaleEffect(0.9).position(x: cursor.x + 6, y: cursor.y + 22)
            }
            // Click ripples.
            ForEach(clicks.indices, id: \.self) { i in
                let c = clicks[i]
                if t >= c && t < c + 0.5 {
                    let u = (t - c) / 0.5
                    Circle().stroke(Color.white.opacity(0.85 * (1 - u)), lineWidth: 2)
                        .frame(width: 8 + 34 * u, height: 8 + 34 * u)
                        .position(cursor)
                }
            }
            Cursor(pressed: pressed).position(x: cursor.x + 6.5, y: cursor.y + 10)
        }
        .frame(width: S.width, height: S.height, alignment: .topLeading)
    }

    func islandHeight(_ t: Double) -> CGFloat {
        let i = islandIndex(t)
        let (t0, cur) = islandKeys[i]
        let prev = i > 0 ? islandKeys[i - 1].1 : cur
        return lerp(prev.size.height, cur.size.height, spring(t - t0))
    }
}

// MARK: - The frame (backdrop, zooming viewport, captions, titles)

struct Frame: View {
    let t: Double

    var body: some View {
        let cam = camera(t)
        let base = viewport.width / S.width
        let k = base * cam.zoom
        let ox = min(0, max(viewport.width - S.width * k, viewport.width / 2 - cam.center.x * k))
        let oy = min(0, max(viewport.height - S.height * k, viewport.height / 2 - cam.center.y * k))
        let screenIn = smooth((t - 2.3) / 0.9) * smooth((64.2 - t) / 0.7)
        let introOpacity = envelope(t, 0.2, 2.9, fade: 0.6)
        let outroOpacity = smooth((t - 62.0) / 0.8)

        ZStack(alignment: .topLeading) {
            Backdrop(t: t)
            // The recording, in a rounded frame, zoomed by the camera.
            ZStack(alignment: .topLeading) {
                Screen(t: t)
                    .scaleEffect(k, anchor: .topLeading)
                    .offset(x: ox, y: oy)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.8), radius: 50, y: 26)
            .scaleEffect(0.94 + 0.06 * screenIn)
            .opacity(screenIn)
            .offset(x: viewport.minX, y: viewport.minY)

            // Caption.
            ForEach(captions.indices, id: \.self) { i in
                let c = captions[i]
                let o = envelope(t, c.0, c.1, fade: 0.3)
                if o > 0 {
                    // A quiet, numbered lower third: "03 │ Caption".
                    HStack(spacing: 16) {
                        Text(String(format: "%02d", i + 1))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.38))
                        Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 18)
                        Text(c.2)
                            .font(.system(size: 23, weight: .medium))
                            .tracking(-0.2)
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .opacity(o)
                    .offset(y: CGFloat(1 - o) * 6)
                    .position(x: frameSize.width / 2, y: viewport.maxY + 36)
                }
            }

            // Keystroke overlay.
            let keyO = envelope(t, 43.7, 45.9, fade: 0.25)
            if keyO > 0 {
                let pressed = keyPresses.contains { t >= $0 && t < $0 + 0.16 }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 22, weight: .semibold))
                    Text("F12").font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: pressed ? 0x0E0E10 : 0x1A1A1D)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(pressed ? 0.3 : 0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
                .scaleEffect(pressed ? 0.94 : 1)
                .opacity(keyO)
                .position(x: viewport.maxX - 110, y: viewport.maxY - 60)
            }

            // Title cards.
            if introOpacity > 0 {
                TitleCard(t: t, subtitle: "An open-source Dynamic Island for your Mac").opacity(introOpacity)
                    .scaleEffect(1.04 - 0.04 * introOpacity)
            }
            if outroOpacity > 0 {
                TitleCard(t: t, subtitle: "Open source. Built with SwiftUI. No telemetry.", footer: "Music  ·  Agents  ·  Battery  ·  Focus  ·  Calendar  ·  Shelf  ·  Themes")
                    .opacity(outroOpacity)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }
}

/// Near-black stage, a faint neutral light from above, and a little film grain.
struct Backdrop: View {
    var t: Double = 0
    var body: some View {
        ZStack {
            Color(hex: 0x09090A)
            RadialGradient(colors: [.white.opacity(0.055), .clear], center: UnitPoint(x: 0.5, y: -0.15), startRadius: 0, endRadius: 1200)
            Image(decorative: Grain.frame(t), scale: 1)
                .resizable()
                .interpolation(.none)
                .opacity(0.05)
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }
}

/// Pre-rendered noise for a subtle film grain.
enum Grain {
    @MainActor static let frames: [CGImage] = [make(seed: 1)]

    /// Static grain: animated noise looks similar but makes the video ~4x larger.
    @MainActor static func frame(_ t: Double) -> CGImage { frames[0] }

    static func make(seed: UInt64) -> CGImage {
        let w = 960, h = 540
        var state = seed &* 0x9E3779B97F4A7C15
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in pixels.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            pixels[i] = UInt8(truncatingIfNeeded: state)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

struct TitleCard: View {
    var t: Double
    var subtitle: String
    var footer: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            // The mark: an island-shaped pill with a hairline and a single live dot.
            Capsule().fill(Color.black)
                .frame(width: 92, height: 30)
                .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                .overlay(Circle().fill(.white).frame(width: 7, height: 7).offset(x: 28))
                .padding(.bottom, 34)
            Text("DynamicIsland4Mac")
                .font(.system(size: 78, weight: .semibold))
                .tracking(-2)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 14)
            if let footer {
                Rectangle().fill(.white.opacity(0.18)).frame(width: 48, height: 1).padding(.top, 34)
                Text(footer.uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.top, 22)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .background(Backdrop(t: t))
    }
}

// MARK: - Rendering

@MainActor
func render(_ t: Double) -> CGImage? {
    let renderer = ImageRenderer(content: Frame(t: t).environment(\.colorScheme, .dark))
    renderer.proposedSize = ProposedViewSize(frameSize)
    renderer.scale = 1
    return renderer.cgImage
}

@main
struct MakeDemo {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: make-demo <output.mp4> | make-demo <dir> --stills t1 t2 …")
            return
        }
        if let i = args.firstIndex(of: "--stills") {
            let dir = URL(fileURLWithPath: args[1])
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for value in args[(i + 1)...] {
                guard let t = Double(value), let image = render(t) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("still-\(value).png"))
                print("wrote still \(value)")
            }
            return
        }

        let url = URL(fileURLWithPath: args[1])
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 14_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = Int(duration * Double(fps))
        let started = Date()
        for frame in 0..<total {
            let t = Double(frame) / Double(fps)
            guard let image = render(t), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(frameSize.width), height: Int(frameSize.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(image, in: CGRect(origin: .zero, size: frameSize))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            if frame % (fps * 5) == 0 {
                print(String(format: "frame %d/%d  (%.0fs elapsed)", frame, total, Date().timeIntervalSince(started)))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        print(writer.status == .completed ? "done: \(url.path)" : "failed: \(writer.error?.localizedDescription ?? "?")")
    }
}

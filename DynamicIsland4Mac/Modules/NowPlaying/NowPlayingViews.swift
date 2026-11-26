import AppKit
import SwiftUI

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.islandPalette) private var palette

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    palette.foreground.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A gradient square used as fake artwork in the Settings preview.
    static func placeholderArtwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSGradient(colors: [NSColor(srgbRed: 1, green: 0.42, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.35, green: 0.3, blue: 0.95, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: -45)
        image.unlockFocus()
        return image
    }
}

/// Four bars that bounce while playing. Not a real audio analysis (that would need Screen
/// Recording permission to tap system audio); a lightweight activity indicator animated by
/// Core Animation, so it costs the app no CPU while it plays. Still with Reduce Motion.
struct WaveformView: View {
    let isPlaying: Bool
    let color: Color

    var body: some View {
        WaveformBars(isAnimating: isPlaying, color: color)
    }
}

struct NowPlayingExpandedView: View {
    let module: NowPlayingModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        if let now = module.media.nowPlaying {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(image: module.media.artwork, size: 76, cornerRadius: 12)
                    .islandMatched("artwork", module: module.id)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(now.title)
                                .font(theme.titleFont)
                                .lineLimit(1)
                            Text([now.artist, now.album].compactMap { $0 }.joined(separator: " — "))
                                .font(theme.bodyFont)
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        AppIconView(bundleID: now.appBundleID)
                    }
                    ProgressScrubber(module: module, now: now)
                    PlaybackControls(module: module, isPlaying: now.isPlaying)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: theme.icons.weight.weight))
                    .foregroundStyle(palette.secondary)
                Text("Nothing playing")
                    .font(theme.titleFont)
                if case .appleScript = module.media.source {
                    Text("Using Music and Spotify only (media adapter unavailable)")
                        .font(theme.captionFont)
                        .foregroundStyle(palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppIconView: View {
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityLabel(FileManager.default.displayName(atPath: url.path))
        }
    }
}

/// Progress bar with elapsed / remaining times. Drag to scrub; the seek is sent on release.
/// Redraws once a second only while playing.
private struct ProgressScrubber: View {
    let module: NowPlayingModule
    let now: NowPlaying
    @State private var dragFraction: Double?
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        if let duration = now.duration, duration > 0 {
            TimelineView(.periodic(from: .now, by: now.isPlaying ? 1 : 3600)) { context in
                let elapsed = dragFraction.map { $0 * duration } ?? (now.elapsed(at: context.date) ?? 0)
                let fraction = min(max(elapsed / duration, 0), 1)
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.foreground.opacity(0.18))
                            Capsule().fill(module.tint)
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                        .frame(height: dragFraction == nil ? 4 : 6)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in dragFraction = min(max(value.location.x / geo.size.width, 0), 1) }
                                .onEnded { _ in
                                    if let f = dragFraction { module.media.seek(to: f * duration) }
                                    dragFraction = nil
                                }
                        )
                    }
                    .frame(height: 10)
                    HStack {
                        Text(Self.format(elapsed))
                        Spacer()
                        Text("-" + Self.format(max(duration - elapsed, 0)))
                    }
                    .font(theme.timerFont)
                    .foregroundStyle(palette.secondary)
                }
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.format(elapsed)) of \(Self.format(duration))")
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? 10.0 : -10.0
                    module.media.seek(to: min(max(elapsed + step, 0), duration))
                }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlaybackControls: View {
    let module: NowPlayingModule
    let isPlaying: Bool
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 22) {
            Spacer()
            button("backward.fill", label: "Previous track") { module.media.send(.previousTrack) }
            button(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", size: 20) { module.media.send(.togglePlayPause) }
            button("forward.fill", label: "Next track") { module.media.send(.nextTrack) }
            Spacer()
        }
    }

    private func button(_ symbol: String, label: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: theme.icons.weight.weight))
                .foregroundStyle(palette.foreground)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TrackAlertView: View {
    let module: NowPlayingModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(image: module.media.artwork, size: 34, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.media.nowPlaying?.title ?? "")
                    .font(theme.titleFont)
                    .lineLimit(1)
                Text(module.media.nowPlaying?.artist ?? "")
                    .font(theme.captionFont)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            Spacer()
            WaveformView(isPlaying: true, color: module.tint)
                .frame(width: 22, height: 14)
        }
        .accessibilityElement(children: .combine)
    }
}

struct NowPlayingSettingsView: View {
    let module: NowPlayingModule
    let context: ModuleContext

    var body: some View {
        switch module.media.source {
        case .adapter:
            Label("Using the MediaRemote adapter: works with every app that plays media.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .appleScript(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("Using AppleScript for Music and Spotify only.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        case .none:
            Label("Not running.", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
        if let error = module.media.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        Toggle("Show an alert when the track changes", isOn: context.boolBinding("trackAlerts", default: true))
        Toggle("Keep showing while paused", isOn: context.boolBinding("showWhenPaused", default: false))
        Picker("Visualizer", selection: context.stringBinding("visualizer", default: NowPlayingModule.Visualizer.artwork.rawValue)) {
            ForEach(NowPlayingModule.Visualizer.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
        Text("The visualizer is an activity animation, not real audio levels: analysing system audio would need Screen Recording permission.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

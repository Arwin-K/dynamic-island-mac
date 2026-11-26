import AppKit
import Observation
import SwiftUI

/// Now Playing: artwork, title, artist, progress, controls, and a small visualizer.
@MainActor
@Observable
final class NowPlayingModule: IslandModule {
    let id = "nowPlaying"
    let displayName = "Now Playing"
    let symbolName = "music.note"
    let priority = 20
    let showsInExpandedWhenIdle = true

    let media: MediaService
    @ObservationIgnored let context: ModuleContext
    /// Artwork tint for the visualizer ("follow artwork" style).
    private(set) var artworkColor: HexColor?
    /// When playback last stopped; the activity lingers briefly so pausing doesn't flicker.
    private var pausedAt: Date?
    private var lingering = false
    @ObservationIgnored private var lingerWork: DispatchWorkItem?

    init(context: ModuleContext, media: MediaService? = nil) {
        self.context = context
        self.media = media ?? MediaService()
    }

    enum Visualizer: String, CaseIterable {
        case waveform, artwork, off
        var label: String {
            switch self {
            case .waveform: "Waveform (accent color)"
            case .artwork: "Waveform (artwork color)"
            case .off: "Off"
            }
        }
    }

    var visualizer: Visualizer { Visualizer(rawValue: context.string("visualizer", default: "artwork")) ?? .artwork }
    private var trackAlerts: Bool { context.bool("trackAlerts", default: true) }
    private var showWhenPaused: Bool { context.bool("showWhenPaused", default: false) }

    var isActive: Bool {
        guard let now = media.nowPlaying else { return false }
        return now.isPlaying || showWhenPaused || lingering
    }

    var tint: Color {
        switch visualizer {
        case .artwork: artworkColor?.color ?? context.services.themeStore.palette.accent
        default: context.services.themeStore.palette.accent
        }
    }

    func start() {
        media.onTrackChange = { [weak self] track in self?.trackChanged(track) }
        media.onArtwork = { [weak self] data in self?.artworkChanged(data) }
        media.start()
        observePlayback()
    }

    func stop() {
        media.stop()
        media.onTrackChange = nil
        media.onArtwork = nil
        context.services.themeStore.albumArtAccent = nil
    }

    private func observePlayback() {
        withObservationTracking {
            _ = media.nowPlaying?.isPlaying
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.playbackChanged()
                self?.observePlayback()
            }
        }
    }

    /// Keep the activity for 8 s after pausing, so a quick pause/resume doesn't make the
    /// island collapse and re-expand.
    private func playbackChanged() {
        lingerWork?.cancel()
        if media.nowPlaying?.isPlaying == false {
            lingering = true
            let work = DispatchWorkItem { [weak self] in self?.lingering = false }
            lingerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        } else {
            lingering = false
        }
    }

    private func trackChanged(_ track: NowPlaying) {
        guard trackAlerts, track.isPlaying else { return }
        // No alert while the island is open: you can already see it.
        guard !context.services.islands.contains(where: { $0.state == .expanded }) else { return }
        context.alert(feedback: .trackChanged, duration: 2.5, coalescingKey: "track") { [weak self] in
            if let self { TrackAlertView(module: self) }
        }
    }

    private func artworkChanged(_ data: Data?) {
        guard let data else {
            artworkColor = nil
            context.services.themeStore.albumArtAccent = nil
            return
        }
        let style = context.services.themeStore.theme.colors.sampleStyle
        Task.detached(priority: .utility) {
            let color = ColorSampler.color(fromImageData: data, style: style)
            await MainActor.run { [weak self] in
                self?.artworkColor = color
                self?.context.services.themeStore.albumArtAccent = color
            }
        }
    }

    // MARK: Views

    func compactLeading() -> some View {
        ArtworkView(image: media.artwork, size: 24, cornerRadius: 6)
            .islandMatched("artwork", module: id)
            .accessibilityLabel(media.nowPlaying.map { "Now playing: \($0.title)" } ?? "Now playing")
    }

    func compactTrailing() -> some View {
        Group {
            if visualizer != .off {
                WaveformView(isPlaying: media.nowPlaying?.isPlaying ?? false, color: tint)
                    .frame(width: 22, height: 14)
            } else {
                Image(systemName: media.nowPlaying?.isPlaying == true ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
            }
        }
        .accessibilityHidden(true)
    }

    func expanded() -> some View {
        NowPlayingExpandedView(module: self)
    }

    func settingsView() -> AnyView {
        AnyView(NowPlayingSettingsView(module: self, context: context))
    }

    /// Fake data for the Settings preview.
    static func preview(context: ModuleContext) -> NowPlayingModule {
        let module = NowPlayingModule(context: context)
        module.media.setPreview(
            NowPlaying(title: "Midnight Drive", artist: "The Placeholders", album: "Demo Tapes", duration: 214, elapsed: 83,
                       timestamp: Date(), rate: 1, isPlaying: false, bundleID: "com.apple.Music", parentBundleID: nil, artworkID: 1),
            artwork: ArtworkView.placeholderArtwork()
        )
        module.lingering = true
        module.artworkColor = HexColor(hex: "#FF6B9A")
        return module
    }
}

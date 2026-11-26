import AppKit

/// Fallback media source for when the MediaRemote adapter stops working: Music and Spotify
/// via their distributed notifications (pushed on every change, so no polling) plus
/// AppleScript for controls and Music's artwork.
///
/// AppleScript runs in short-lived `osascript` processes off the main thread, so a slow or
/// hung player never blocks the UI. The first command to each app triggers macOS's
/// Automation permission prompt.
///
/// Spotify only exposes artwork as a URL on the internet; since the app makes no network
/// requests, Spotify tracks show without artwork in this fallback.
@MainActor
final class AppleScriptMediaSource {
    private let onUpdate: (NowPlaying?, Data?) -> Void
    private var observers: [NSObjectProtocol] = []
    private var lastArtworkKey: String?

    private static let music = "com.apple.Music"
    private static let spotify = "com.spotify.client"

    init(onUpdate: @escaping (NowPlaying?, Data?) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note.userInfo ?? [:], bundleID: Self.music) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note.userInfo ?? [:], bundleID: Self.spotify) }
        })
        Log.media.info("Using AppleScript fallback for Music and Spotify")
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    private func handle(_ info: [AnyHashable: Any], bundleID: String) {
        let state = info["Player State"] as? String ?? "Stopped"
        guard state != "Stopped", let title = info["Name"] as? String else {
            onUpdate(nil, nil)
            return
        }
        // Music reports milliseconds in "Total Time"; Spotify in "Duration".
        let durationMs = (info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue
        let artist = info["Artist"] as? String
        var nowPlaying = NowPlaying(
            title: title, artist: artist, album: info["Album"] as? String,
            duration: durationMs.map { $0 / 1000 }, elapsed: position, timestamp: position == nil ? nil : Date(),
            rate: 1, isPlaying: state == "Playing", bundleID: bundleID, parentBundleID: nil, artworkID: nil
        )
        let artworkKey = "\(bundleID)|\(title)|\(artist ?? "")"
        nowPlaying.artworkID = artworkKey.hashValue
        onUpdate(nowPlaying, nil)

        // Music doesn't include the position in its notification; ask for it, and for the
        // artwork when the track changed.
        let needsArtwork = artworkKey != lastArtworkKey && bundleID == Self.music
        lastArtworkKey = artworkKey
        guard bundleID == Self.music else { return }
        Task.detached(priority: .utility) {
            let position = Double(Self.osascript("tell application \"Music\" to get player position") ?? "")
            let artwork = needsArtwork ? Self.musicArtwork() : nil
            await MainActor.run { [weak self] in
                var updated = nowPlaying
                if let position { updated.elapsed = position; updated.timestamp = Date() }
                self?.onUpdate(updated, artwork)
            }
        }
    }

    func send(_ command: MediaService.Command, bundleID: String?) {
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        }
        Task.detached { _ = Self.osascript("tell application \"\(app)\" to \(verb)") }
    }

    func seek(to seconds: Double, bundleID: String?) {
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        Task.detached { _ = Self.osascript("tell application \"\(app)\" to set player position to \(seconds)") }
    }

    /// Writes the current track's artwork to a temp file via AppleScript and reads it back.
    nonisolated private static func musicArtwork() -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("di4m-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let script = """
        tell application "Music"
            if (count of artworks of current track) is 0 then return "none"
            set d to raw data of artwork 1 of current track
        end tell
        set f to open for access (POSIX file "\(url.path)") with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        """
        guard osascript(script) == "ok" else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Runs AppleScript in `osascript` (call off the main thread). Returns trimmed stdout.
    nonisolated static func osascript(_ source: String, timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

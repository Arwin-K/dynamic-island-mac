import AppKit
import Observation

/// Now-playing information and playback control.
///
/// ## Why a Perl script?
///
/// Since macOS 15.4 the private MediaRemote framework only answers processes whose bundle
/// identifier starts with `com.apple.`. `mediaremote-adapter` works around that by running
/// `/usr/bin/perl` (which is `com.apple.perl`) and loading a small helper framework into it.
/// We bundle the script, the framework and its test client (built by our Xcode targets, no
/// CMake), and talk to it over stdout:
///
/// * `test` once at launch: exit code 0 means the adapter works on this macOS version.
/// * `stream`: one long-running process that prints a JSON line whenever anything changes.
///   It is event driven, so it costs nothing while the music is unchanged.
/// * `send <command>` / `seek <microseconds>`: short-lived processes for controls.
///
/// If `test` fails (Apple closed the loophole), we fall back to AppleScript for Music and
/// Spotify, which post distributed notifications on every change (again, no polling).
@MainActor
@Observable
final class MediaService {
    enum Source: Equatable {
        case none
        case adapter
        case appleScript(reason: String)
    }

    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var source: Source = .none
    /// Shown in Settings when something went wrong.
    private(set) var lastError: String?
    /// Called after the track changes (new title/artist), for "track changed" alerts.
    @ObservationIgnored var onTrackChange: ((NowPlaying) -> Void)?
    /// Called with raw artwork bytes when the artwork changes, for album-art accents.
    @ObservationIgnored var onArtwork: ((CGImage?) -> Void)?

    @ObservationIgnored private var streamProcess: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var streamStartedAt = Date()
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    @ObservationIgnored private var appleScript: AppleScriptMediaSource?
    @ObservationIgnored private var started = false

    // MARK: - Bundled adapter paths

    struct AdapterPaths {
        let script: String
        let framework: String
        let testClient: String
    }

    nonisolated static var adapterPaths: AdapterPaths? {
        let bundle = Bundle.main
        guard let script = bundle.path(forResource: "mediaremote-adapter", ofType: "pl") else { return nil }
        let framework = bundle.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework").path
        let testClient = bundle.bundleURL.appendingPathComponent("Contents/MacOS/MediaRemoteAdapterTestClient").path
        guard FileManager.default.fileExists(atPath: framework) else { return nil }
        return AdapterPaths(script: script, framework: framework, testClient: testClient)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        stopping = false
        guard let paths = Self.adapterPaths else {
            useAppleScript(reason: "The media adapter isn't bundled in this build.")
            return
        }
        Self.reapOrphanedStreams()
        // `test` can take a few seconds (it may briefly start a helper); keep it off the main thread.
        Task.detached(priority: .utility) {
            let result = Self.run(paths: paths, arguments: ["test"], timeout: 15)
            await MainActor.run { [weak self] in
                guard let self, self.started else { return }
                if result.status == 0 {
                    Log.media.info("Media adapter test passed")
                    self.source = .adapter
                    self.startStream(paths: paths)
                } else {
                    let reason = "The media adapter test failed (exit \(result.status)). macOS may have blocked it."
                    Log.media.error("\(reason, privacy: .public) \(result.stderr, privacy: .public)")
                    self.useAppleScript(reason: reason)
                }
            }
        }
    }

    func stop() {
        started = false
        stopping = true
        restartWork?.cancel()
        streamProcess?.terminate()
        streamProcess = nil
        appleScript?.stop()
        appleScript = nil
        nowPlaying = nil
        artwork = nil
        source = .none
    }

    private func useAppleScript(reason: String) {
        source = .appleScript(reason: reason)
        let fallback = AppleScriptMediaSource { [weak self] info, artworkData in
            self?.apply(nowPlaying: info, artwork: artworkData.flatMap { Self.thumbnail($0) }, artworkChanged: artworkData != nil || info == nil)
        }
        appleScript = fallback
        fallback.start()
    }

    // MARK: - Stream

    private func startStream(paths: AdapterPaths) {
        guard !stopping else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, paths.testClient, "stream", "--debounce=80"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Parsing happens on the pipe's background queue; only results hop to the main actor.
        let reader = LineReader()
        var state: [String: Any] = [:]
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in reader.append(data) {
                guard let update = NowPlayingParser.apply(line: line, to: &state) else { continue }
                // Decode + downsample here, off the main thread.
                let thumbnail = update.artworkData.flatMap { Self.thumbnail($0) }
                DispatchQueue.main.async {
                    self?.apply(nowPlaying: update.nowPlaying, artwork: thumbnail, artworkChanged: update.artworkChanged)
                }
            }
        }
        // Every stderr line is an error message; non-fatal ones can be ignored (per the adapter docs).
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) {
                Log.media.debug("adapter stderr: \(text, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { self?.streamEnded(status: status, paths: paths) }
        }
        do {
            try process.run()
            streamProcess = process
            streamStartedAt = Date()
        } catch {
            lastError = "Could not start the media adapter: \(error.localizedDescription)"
            useAppleScript(reason: lastError ?? "")
        }
    }

    /// The adapter docs advise against re-invoking after a fatal error, and the spec asks for a
    /// restart with backoff, so: restart a few times with growing delays (a crash after sleep or
    /// a transient failure recovers), then give up and fall back to AppleScript.
    private func streamEnded(status: Int32, paths: AdapterPaths) {
        streamProcess = nil
        guard !stopping, started else { return }
        if Date().timeIntervalSince(streamStartedAt) > 120 { restartAttempts = 0 }
        restartAttempts += 1
        Log.media.error("Media stream exited with status \(status); restart attempt \(self.restartAttempts)")
        guard restartAttempts <= 5 else {
            lastError = "The media adapter kept exiting (status \(status))."
            useAppleScript(reason: lastError ?? "")
            return
        }
        let delay = min(pow(2, Double(restartAttempts - 1)), 30)
        let work = DispatchWorkItem { [weak self] in self?.startStream(paths: paths) }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply(nowPlaying new: NowPlaying?, artwork image: CGImage?, artworkChanged: Bool) {
        let old = nowPlaying
        nowPlaying = new
        if artworkChanged {
            artwork = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            onArtwork?(image)
        }
        if let new, new.title != old?.title || new.artist != old?.artist {
            onTrackChange?(new)
        }
    }

    /// Artwork is shown at most 92 pt (184 px on Retina), but players send it at up to a few
    /// thousand pixels. Decoding to a 256 px thumbnail keeps each track's artwork at ~256 KB in
    /// memory instead of several MB.
    nonisolated static func thumbnail(_ data: Data, maxPixels: Int = 256) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Controls

    /// MediaRemote command ids (`kMR…` in the adapter's MediaRemote.h).
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5
    }

    func send(_ command: Command) {
        switch source {
        case .adapter:
            guard let paths = Self.adapterPaths else { return }
            Task.detached(priority: .userInitiated) { _ = Self.run(paths: paths, arguments: ["send", String(command.rawValue)], timeout: 5) }
        case .appleScript:
            appleScript?.send(command, bundleID: nowPlaying?.bundleID)
        case .none:
            break
        }
    }

    func seek(to seconds: Double) {
        switch source {
        case .adapter:
            guard let paths = Self.adapterPaths else { return }
            let micros = String(Int64(max(seconds, 0) * 1_000_000))
            Task.detached(priority: .userInitiated) { _ = Self.run(paths: paths, arguments: ["seek", micros], timeout: 5) }
        case .appleScript:
            appleScript?.seek(to: seconds, bundleID: nowPlaying?.bundleID)
        case .none:
            break
        }
        // Optimistically move the position so the scrubber doesn't jump back.
        if var current = nowPlaying {
            current.elapsed = seconds
            current.timestamp = Date()
            nowPlaying = current
        }
    }

    /// Settings preview only: show fake data.
    func setPreview(_ nowPlaying: NowPlaying, artwork: NSImage?) {
        self.nowPlaying = nowPlaying
        self.artwork = artwork
    }

    /// A `stream` process outlives us if the app crashes or is force-killed (macOS has no
    /// "die with parent" flag). On start, kill any adapter streams that were orphaned
    /// (re-parented to launchd) and belong to this app.
    nonisolated static func reapOrphanedStreams() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let marker = "MediaRemoteAdapter.framework"
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), parts[1] == "1",
                  parts[2].contains("mediaremote-adapter.pl"), parts[2].contains(marker),
                  parts[2].contains(Bundle.main.bundleURL.lastPathComponent)
            else { continue }
            kill(pid, SIGTERM)
            Log.media.info("Stopped orphaned adapter stream \(pid)")
        }
    }

    // MARK: - Process helper

    struct RunResult {
        var status: Int32
        var stderr: String
    }

    /// Runs one adapter command synchronously (call off the main thread).
    nonisolated static func run(paths: AdapterPaths, arguments: [String], timeout: TimeInterval) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.framework, paths.testClient] + arguments
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return RunResult(status: -1, stderr: error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return RunResult(status: -2, stderr: "timed out")
        }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(status: process.terminationStatus, stderr: err)
    }
}

/// Splits a byte stream into lines. Used from one serial queue only.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}

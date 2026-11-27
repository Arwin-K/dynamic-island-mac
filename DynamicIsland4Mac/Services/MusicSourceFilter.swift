import Foundation

/// Decides whether a now-playing report is music we want to show.
///
/// MediaRemote reports whatever the system considers "now playing", which includes any
/// browser tab with audio (a news video, a Twitch stream, a meeting). We only want music
/// from YouTube, Spotify and Apple Music, so:
///
/// * The native players (Music, Spotify, the YouTube Music desktop app) are always allowed.
/// * For a browser, MediaRemote doesn't say which site is playing, so we ask the browser for
///   its tabs over AppleScript and allow the report only if a music tab matches:
///   - `youtube.com`: the tab's title must contain the track title (YouTube titles its tabs
///     "<video title> - YouTube"), so another site playing while YouTube sits open in a
///     background tab is still hidden.
///   - `music.youtube.com`, `open.spotify.com`, `music.apple.com`: these sites only play music
///     and don't always put the track in the tab title, so an open tab is enough.
/// * Anything else (other apps, Firefox, which has no AppleScript tab access) is hidden.
///
/// Browser checks run in `osascript` off the main thread and are cached per app and title, so
/// play/pause and position updates don't trigger them again. The first check per browser
/// triggers macOS's Automation permission prompt; if it's denied, that browser stays hidden.
@MainActor
final class MusicSourceFilter {
    enum Verdict: Equatable {
        case allowed
        case blocked
        /// A browser check is running; `onResolve` is called when it finishes.
        case pending
    }

    /// Called on the main actor when a pending check finishes.
    var onResolve: (() -> Void)?
    /// Called when a browser refused Automation access (message for Settings).
    var onAccessDenied: ((String) -> Void)?

    private var cache: [String: Bool] = [:]
    private var inFlight: Set<String> = []

    static let musicApps: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes",
        "com.spotify.client",
        "com.github.th-ch.youtube-music",   // YouTube Music desktop app (th-ch)
        "com.github.pear-devs.pear-desktop", // its renamed successor
    ]

    enum Dialect: Sendable {
        /// Tabs have `URL` and `name` (Safari).
        case safari
        /// Tabs have `URL` and `title` (Chrome and its relatives).
        case chromium
    }

    struct Browser: Sendable {
        let bundleID: String
        let name: String
        let dialect: Dialect
    }

    static let browsers: [Browser] = [
        Browser(bundleID: "com.apple.Safari", name: "Safari", dialect: .safari),
        Browser(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", dialect: .safari),
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", dialect: .chromium),
        Browser(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", dialect: .chromium),
        Browser(bundleID: "com.google.Chrome.dev", name: "Google Chrome Dev", dialect: .chromium),
        Browser(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", dialect: .chromium),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium", dialect: .chromium),
        Browser(bundleID: "com.brave.Browser", name: "Brave", dialect: .chromium),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", dialect: .chromium),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", dialect: .chromium),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", dialect: .chromium),
        Browser(bundleID: "com.operasoftware.Opera", name: "Opera", dialect: .chromium),
    ]

    /// Sites that only play music: an open tab is enough.
    static let musicOnlyHosts = ["music.youtube.com", "open.spotify.com", "music.apple.com"]
    /// Sites that play anything: the tab title must contain the track title.
    static let titleMatchHosts = ["youtube.com"]

    func verdict(for info: NowPlaying) -> Verdict {
        let ids = [info.parentBundleID, info.bundleID].compactMap { $0 }
        if ids.contains(where: Self.musicApps.contains) { return .allowed }
        guard let browser = ids.lazy.compactMap(Self.browser(for:)).first else { return .blocked }

        let key = "\(browser.bundleID)|\(info.title)"
        if let cached = cache[key] { return cached ? .allowed : .blocked }
        if !inFlight.contains(key) {
            inFlight.insert(key)
            let title = info.title
            Task.detached(priority: .userInitiated) {
                let tabs = Self.tabs(of: browser)
                let allowed = tabs.map { Self.isMusic(title: title, tabs: $0) } ?? false
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.inFlight.remove(key)
                    if self.cache.count > 64 { self.cache.removeAll() }
                    self.cache[key] = allowed
                    if tabs == nil {
                        Log.media.error("Couldn't read tabs from \(browser.name, privacy: .public); hiding its media")
                        self.onAccessDenied?("Allow DynamicIsland4Mac to control \(browser.name) in System Settings → Privacy & Security → Automation to show YouTube, Spotify and Apple Music playing in it.")
                    }
                    self.onResolve?()
                }
            }
        }
        return .pending
    }

    /// The browser for a bundle ID, matching helper IDs such as `com.google.Chrome.helper`
    /// (the longest match wins, so Chrome Beta isn't mistaken for Chrome).
    nonisolated static func browser(for bundleID: String) -> Browser? {
        browsers
            .filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    struct Tab: Equatable, Sendable {
        var url: String
        var title: String
    }

    nonisolated static func isMusic(title: String, tabs: [Tab]) -> Bool {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        for tab in tabs {
            guard let host = URL(string: tab.url)?.host?.lowercased() else { continue }
            if musicOnlyHosts.contains(where: { matches(host, $0) }) { return true }
            if titleMatchHosts.contains(where: { matches(host, $0) }),
               tab.title.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    private nonisolated static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Every tab's URL and title, or nil if the browser refused (no Automation access).
    nonisolated static func tabs(of browser: Browser) -> [Tab]? {
        let titleProperty = browser.dialect == .safari ? "name" : "title"
        // `tab` is a class in browser dictionaries, so build separators outside the tell block.
        let script = """
        set sep to character id 31
        set nl to character id 30
        set out to ""
        if application id "\(browser.bundleID)" is running then
            tell application id "\(browser.bundleID)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t as text) & sep & (\(titleProperty) of t as text) & nl
                    end repeat
                end repeat
            end tell
        end if
        return out
        """
        guard let output = AppleScriptMediaSource.osascript(script) else { return nil }
        return parseTabs(output)
    }

    nonisolated static func parseTabs(_ output: String) -> [Tab] {
        output.split(separator: "\u{1E}").compactMap { record in
            let parts = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return Tab(url: parts[0].trimmingCharacters(in: .whitespacesAndNewlines), title: String(parts[1]))
        }
    }
}

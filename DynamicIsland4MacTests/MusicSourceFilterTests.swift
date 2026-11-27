import Foundation
import Testing
@testable import DynamicIsland4Mac

struct MusicSourceFilterTests {
    private typealias Tab = MusicSourceFilter.Tab

    @Test @MainActor func musicAppsAreAllowedAndOtherAppsBlocked() {
        let filter = MusicSourceFilter()
        #expect(filter.verdict(for: NowPlaying(title: "Song", isPlaying: true, bundleID: "com.spotify.client")) == .allowed)
        #expect(filter.verdict(for: NowPlaying(title: "Song", isPlaying: true, bundleID: "com.apple.Music")) == .allowed)
        #expect(filter.verdict(for: NowPlaying(title: "Episode", isPlaying: true, bundleID: "com.apple.podcasts")) == .blocked)
        #expect(filter.verdict(for: NowPlaying(title: "Video", isPlaying: true, bundleID: "org.mozilla.firefox")) == .blocked)
    }

    @Test func findsBrowserByHelperBundleID() {
        #expect(MusicSourceFilter.browser(for: "com.google.Chrome")?.name == "Google Chrome")
        #expect(MusicSourceFilter.browser(for: "com.google.Chrome.helper")?.name == "Google Chrome")
        #expect(MusicSourceFilter.browser(for: "com.google.Chrome.beta")?.name == "Google Chrome Beta")
        #expect(MusicSourceFilter.browser(for: "com.apple.Safari")?.dialect == .safari)
        #expect(MusicSourceFilter.browser(for: "com.apple.WebKit.GPU") == nil)
    }

    @Test func youTubeNeedsMatchingTabTitle() {
        let tabs = [
            Tab(url: "https://www.youtube.com/watch?v=abc", title: "(3) Daft Punk - Around the World - YouTube"),
            Tab(url: "https://www.twitch.tv/someone", title: "someone - Twitch"),
        ]
        #expect(MusicSourceFilter.isMusic(title: "Daft Punk - Around the World", tabs: tabs))
        #expect(!MusicSourceFilter.isMusic(title: "Live stream", tabs: tabs))
    }

    @Test func musicOnlySitesNeedJustATab() {
        #expect(MusicSourceFilter.isMusic(title: "Song", tabs: [Tab(url: "https://open.spotify.com/album/1", title: "Spotify")]))
        #expect(MusicSourceFilter.isMusic(title: "Song", tabs: [Tab(url: "https://music.youtube.com/watch?v=1", title: "YouTube Music")]))
        #expect(MusicSourceFilter.isMusic(title: "Song", tabs: [Tab(url: "https://music.apple.com/us/album/1", title: "Album")]))
        #expect(!MusicSourceFilter.isMusic(title: "Song", tabs: [Tab(url: "https://notyoutube.com/", title: "Song")]))
        #expect(!MusicSourceFilter.isMusic(title: "Song", tabs: []))
    }

    @Test func parsesAppleScriptOutput() {
        let output = "https://a.com\u{1F}A title\u{1E}https://b.com\u{1F}B\u{1E}"
        #expect(MusicSourceFilter.parseTabs(output) == [Tab(url: "https://a.com", title: "A title"), Tab(url: "https://b.com", title: "B")])
    }
}

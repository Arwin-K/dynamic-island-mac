import Foundation
import Testing
@testable import DynamicIsland4Mac

struct NowPlayingParserTests {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func fullPayloadThenDiffs() throws {
        var state: [String: Any] = [:]
        let first = try #require(NowPlayingParser.apply(line: line(##"{"type":"data","diff":false,"payload":{"title":"A","artist":"X","playing":true,"duration":200,"elapsedTime":10,"timestamp":"2026-11-26T19:10:24Z","bundleIdentifier":"com.spotify.client","artworkData":"aGVsbG8="}}"##), to: &state))
        #expect(first.nowPlaying?.title == "A")
        #expect(first.nowPlaying?.isPlaying == true)
        #expect(first.artworkChanged)
        #expect(first.artworkData == Data("hello".utf8))

        // Diff: pause, artwork unchanged.
        let second = try #require(NowPlayingParser.apply(line: line(##"{"type":"data","diff":true,"payload":{"playing":false}}"##), to: &state))
        #expect(second.nowPlaying?.title == "A")
        #expect(second.nowPlaying?.isPlaying == false)
        #expect(!second.artworkChanged)

        // Diff with null removes the key.
        let third = try #require(NowPlayingParser.apply(line: line(##"{"type":"data","diff":true,"payload":{"artist":null,"artworkData":null}}"##), to: &state))
        #expect(third.nowPlaying?.artist == nil)
        #expect(third.artworkChanged)
        #expect(third.artworkData == nil)
    }

    @Test func emptyPayloadMeansNothingPlaying() throws {
        var state: [String: Any] = ["title": "A", "playing": true]
        let update = try #require(NowPlayingParser.apply(line: line(##"{"type":"data","diff":false,"payload":{}}"##), to: &state))
        #expect(update.nowPlaying == nil)
    }

    @Test func ignoresGarbage() {
        var state: [String: Any] = [:]
        #expect(NowPlayingParser.apply(line: line("not json"), to: &state) == nil)
        #expect(NowPlayingParser.apply(line: line(##"{"type":"other"}"##), to: &state) == nil)
    }

    @Test func extrapolatesPositionWhilePlaying() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var now = NowPlaying(title: "A", duration: 100, elapsed: 10, timestamp: t0, rate: 1, isPlaying: true)
        #expect(now.elapsed(at: t0.addingTimeInterval(5)) == 15)
        #expect(now.elapsed(at: t0.addingTimeInterval(500)) == 100)
        now.isPlaying = false
        #expect(now.elapsed(at: t0.addingTimeInterval(5)) == 10)
    }

    @Test func lineReaderSplitsAcrossChunks() {
        let reader = LineReader()
        #expect(reader.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        let rest = reader.append(Data(":2}\n\n".utf8))
        #expect(rest.count == 1)
        #expect(String(data: rest[0], encoding: .utf8) == "{\"b\":2}")
    }
}

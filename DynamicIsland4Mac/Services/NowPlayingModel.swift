import Foundation

/// What's playing, normalized from either the media adapter or the AppleScript fallback.
struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String? = nil
    var album: String? = nil
    /// Seconds.
    var duration: Double? = nil
    /// Elapsed seconds at `timestamp`.
    var elapsed: Double? = nil
    var timestamp: Date? = nil
    var rate: Double = 1
    var isPlaying: Bool
    var bundleID: String? = nil
    var parentBundleID: String? = nil
    /// Changes whenever the artwork changes (so views know to reload it).
    var artworkID: Int? = nil

    /// Estimated position now, extrapolated from the last report while playing.
    func elapsed(at now: Date) -> Double? {
        guard let elapsed else { return nil }
        guard isPlaying, let timestamp else { return elapsed }
        let position = elapsed + now.timeIntervalSince(timestamp) * (rate == 0 ? 1 : rate)
        if let duration, duration > 0 { return min(max(position, 0), duration) }
        return max(position, 0)
    }

    /// The app to show an icon for (a browser rather than its WebKit helper).
    var appBundleID: String? { parentBundleID ?? bundleID }
}

/// Parses the adapter's line-delimited JSON (`stream` command) and applies diffs.
///
/// Each line is `{"type":"data","diff":Bool,"payload":{…}}`. A non-diff payload replaces the
/// state; a diff payload updates only the keys it contains, and a key set to `null` is removed.
/// An empty payload means nothing is playing.
enum NowPlayingParser {
    struct Update {
        var nowPlaying: NowPlaying?
        /// Raw artwork bytes when the artwork changed in this update.
        var artworkData: Data?
        var artworkChanged: Bool
    }

    static func apply(line: Data, to state: inout [String: Any]) -> Update? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "data",
              let payload = object["payload"] as? [String: Any]
        else { return nil }

        let previousKey = state[artworkKey] as? String
        if (object["diff"] as? Bool) == true {
            for (key, value) in payload {
                if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
            }
            if payload["artworkData"] is NSNull { state.removeValue(forKey: artworkKey) }
        } else {
            state = payload
        }
        // Artwork arrives as base64 (often hundreds of KB). Keep only a fingerprint in the
        // merged state, so the string isn't held in memory for the rest of the track; decode
        // only when the artwork actually changed.
        var artworkData: Data?
        if let raw = state.removeValue(forKey: "artworkData") as? String {
            let key = fingerprint(raw)
            state[artworkKey] = key
            if key != previousKey { artworkData = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) }
        }
        let artworkChanged = (state[artworkKey] as? String) != previousKey
        return Update(nowPlaying: nowPlaying(from: state), artworkData: artworkData, artworkChanged: artworkChanged)
    }

    private static let artworkKey = "_artworkFingerprint"

    private static func fingerprint(_ base64: String) -> String {
        "\(base64.count):\(base64.prefix(48)):\(base64.suffix(48))"
    }

    static func nowPlaying(from dict: [String: Any]) -> NowPlaying? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        let artwork = dict[artworkKey] as? String
        return NowPlaying(
            title: title,
            artist: (dict["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (dict["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            duration: number(dict["duration"]),
            elapsed: number(dict["elapsedTime"]),
            timestamp: date(dict["timestamp"]),
            rate: number(dict["playbackRate"]) ?? 1,
            isPlaying: dict["playing"] as? Bool ?? false,
            bundleID: dict["bundleIdentifier"] as? String,
            parentBundleID: dict["parentApplicationBundleIdentifier"] as? String,
            artworkID: artwork.map { $0.hashValue }
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

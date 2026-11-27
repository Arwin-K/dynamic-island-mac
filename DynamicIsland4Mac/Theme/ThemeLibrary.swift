import Foundation
import Observation

/// All available themes: the built-in presets shipped in the app bundle (`Themes/*.json` in
/// the repo) and the user's themes in `~/Library/Application Support/DynamicIsland4Mac/Themes/`.
///
/// A user theme with the same `id` as a built-in *shadows* it ("customized"); "Reset to
/// default" deletes the user file and the built-in comes back.
///
/// The user folder is watched with FSEvents, so editing a theme in a text editor updates the
/// island live.
@MainActor
@Observable
final class ThemeLibrary {
    struct Entry: Identifiable, Equatable {
        var theme: Theme
        var isBuiltIn: Bool
        /// A user file overrides the built-in with the same id.
        var isCustomized: Bool
        var fileURL: URL?
        var warnings: [String]
        var id: String { theme.id }
    }

    private(set) var builtIns: [Theme] = []
    private(set) var userThemes: [String: (theme: Theme, url: URL, warnings: [String])] = [:]
    /// Errors to show in Settings (failed writes, unreadable files).
    private(set) var lastError: String?

    /// Called after the user folder changes on disk.
    @ObservationIgnored var onUserThemesChanged: (() -> Void)?

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    /// Bytes we wrote most recently per file, so our own saves don't bounce back as "external edits".
    @ObservationIgnored private var lastWritten: [URL: Data] = [:]

    /// - Parameter directory: the user themes folder; `nil` for in-memory use (tests, previews).
    init(directory: URL?, builtInDirectory: URL? = Bundle.main.url(forResource: "Themes", withExtension: nil)) {
        self.directory = directory
        builtIns = Self.loadThemes(in: builtInDirectory).map(\.theme).sorted { Self.builtInOrder($0.id) < Self.builtInOrder($1.id) }
        if builtIns.isEmpty { builtIns = [.default] }
        reloadUserThemes()
    }

    static let builtInIDs = ["stealth", "glass", "wallpaper-match", "graphite-minimal", "neon-terminal", "pastel-rounded"]
    private static func builtInOrder(_ id: String) -> Int { builtInIDs.firstIndex(of: id) ?? builtInIDs.count }

    var entries: [Entry] {
        var result: [Entry] = builtIns.map { builtIn in
            if let user = userThemes[builtIn.id] {
                return Entry(theme: user.theme, isBuiltIn: true, isCustomized: true, fileURL: user.url, warnings: user.warnings)
            }
            return Entry(theme: builtIn, isBuiltIn: true, isCustomized: false, fileURL: nil, warnings: [])
        }
        let builtInIDs = Set(builtIns.map(\.id))
        let custom = userThemes.values
            .filter { !builtInIDs.contains($0.theme.id) }
            .sorted { $0.theme.name.localizedCaseInsensitiveCompare($1.theme.name) == .orderedAscending }
        result += custom.map { Entry(theme: $0.theme, isBuiltIn: false, isCustomized: false, fileURL: $0.url, warnings: $0.warnings) }
        return result
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }
    func theme(id: String) -> Theme? { entry(id: id)?.theme }
    func builtIn(id: String) -> Theme? { builtIns.first { $0.id == id } }

    // MARK: - Watching

    func startWatching() {
        guard let directory, watcher == nil else { return }
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.reloadUserThemes() { self.onUserThemesChanged?() }
            }
        }
    }

    /// Re-reads the user folder. Returns true when something actually changed.
    @discardableResult
    func reloadUserThemes() -> Bool {
        guard let directory else { return false }
        var fresh: [String: (theme: Theme, url: URL, warnings: [String])] = [:]
        for loaded in Self.loadThemes(in: directory) {
            fresh[loaded.theme.id] = (loaded.theme, loaded.url, loaded.warnings)
            loaded.warnings.forEach { Log.theme.warning("\(loaded.url.lastPathComponent, privacy: .public): \($0, privacy: .public)") }
        }
        let changed = fresh.mapValues(\.theme) != userThemes.mapValues(\.theme)
            || fresh.mapValues(\.warnings) != userThemes.mapValues(\.warnings)
        if changed { userThemes = fresh }
        return changed
    }

    struct Loaded {
        var theme: Theme
        var url: URL
        var warnings: [String]
    }

    nonisolated static func loadThemes(in directory: URL?) -> [Loaded] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data, fileStem: url.deletingPathExtension().lastPathComponent, url: url)
        }
    }

    /// Decodes a theme file. A file without an `id` gets its file name as the id, and one
    /// without a `name` gets a readable version of the id.
    nonisolated static func decode(_ data: Data, fileStem: String, url: URL) -> Loaded {
        let result = TolerantDecoder.decode(Theme.self, from: data, defaults: .default)
        var theme = result.value
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (raw?["id"] as? String)?.isEmpty ?? true { theme.id = fileStem }
        if (raw?["name"] as? String)?.isEmpty ?? true {
            theme.name = fileStem.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return Loaded(theme: theme, url: url, warnings: result.warnings)
    }

    // MARK: - Writing

    /// Encodes only what differs from `Theme.default` (plus `id` and `name`).
    ///
    /// Why: a theme file that spells out every value freezes today's defaults. If a later
    /// version makes the expanded island smaller, a theme saved with the old full set of
    /// values would keep the old size forever. Loading fills missing keys from the defaults
    /// (`TolerantDecoder`), so the minimal file decodes to exactly the same theme.
    nonisolated static func encodeMinimal(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        let full = try JSONSerialization.jsonObject(with: encoder.encode(theme))
        let base = try JSONSerialization.jsonObject(with: encoder.encode(Theme.default))
        var diff = difference(full, base) as? [String: Any] ?? [:]
        diff["id"] = theme.id
        diff["name"] = theme.name
        return try JSONSerialization.data(withJSONObject: diff, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The parts of `value` that differ from `base` (nil when identical). Nested objects are
    /// compared key by key; keys missing from `base` are kept whole.
    nonisolated static func difference(_ value: Any, _ base: Any?) -> Any? {
        if let dict = value as? [String: Any], let baseDict = base as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, child) in dict {
                if let d = difference(child, baseDict[key]) { out[key] = d }
            }
            return out.isEmpty ? nil : out
        }
        if let base, (value as AnyObject).isEqual(base) { return nil }
        return value
    }

    nonisolated static func encode(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    /// Writes the theme to the user folder (creating a customized copy for a built-in).
    func save(_ theme: Theme) {
        guard let directory else {
            userThemes[theme.id] = (theme, URL(fileURLWithPath: "/dev/null"), [])
            return
        }
        let url = userThemes[theme.id]?.url ?? directory.appendingPathComponent(Self.fileName(for: theme.id))
        do {
            let data = try Self.encodeMinimal(theme)
            try data.write(to: url, options: .atomic)
            lastWritten[url] = data
            userThemes[theme.id] = (theme, url, [])
            lastError = nil
        } catch {
            lastError = "Could not save theme: \(error.localizedDescription)"
            Log.theme.error("\(self.lastError ?? "", privacy: .public)")
        }
    }

    /// Creates a new user theme from `theme` with a unique id and " Copy" name.
    func duplicate(_ theme: Theme) -> Theme {
        var copy = theme
        copy.id = uniqueID(base: theme.id + "-copy")
        copy.name = theme.name + " Copy"
        save(copy)
        return copy
    }

    func delete(id: String) {
        guard let entry = userThemes[id] else { return }
        try? FileManager.default.removeItem(at: entry.url)
        userThemes.removeValue(forKey: id)
    }

    /// Built-ins: drop the user's customizations. Custom themes: reset every value to the
    /// app defaults while keeping the id and name.
    func reset(id: String) -> Theme {
        if let builtIn = builtIn(id: id) {
            delete(id: id)
            return builtIn
        }
        var fresh = Theme.default
        fresh.id = id
        fresh.name = userThemes[id]?.theme.name ?? id
        save(fresh)
        return fresh
    }

    func importTheme(from url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        var theme = Self.decode(data, fileStem: url.deletingPathExtension().lastPathComponent, url: url).theme
        if entry(id: theme.id) != nil { theme.id = uniqueID(base: theme.id) }
        save(theme)
        return theme
    }

    func export(_ theme: Theme, to url: URL) throws {
        try Self.encodeMinimal(theme).write(to: url, options: .atomic)
    }

    private func uniqueID(base: String) -> String {
        let slug = base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        var candidate = slug
        var n = 2
        while entry(id: candidate) != nil {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        return candidate
    }

    nonisolated static func fileName(for id: String) -> String {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(safe) + ".json"
    }

    /// True if `data` at `url` is exactly what we last wrote (an echo of our own save).
    func isOwnWrite(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return lastWritten[url] == data
    }
}

/// Watches a folder with FSEvents and calls back (on the main queue) when anything inside
/// changes. FSEvents coalesces bursts (editors often write a temp file and rename it), and
/// costs nothing while the folder is quiet.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init(url: URL, latency: TimeInterval = 0.25, callback: @escaping () -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().callback()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

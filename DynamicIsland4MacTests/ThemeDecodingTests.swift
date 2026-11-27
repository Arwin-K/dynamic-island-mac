import Foundation
import Testing
@testable import DynamicIsland4Mac

struct ThemeDecodingTests {
    private func decode(_ json: String) -> TolerantDecoder.Result<Theme> {
        TolerantDecoder.decode(Theme.self, from: Data(json.utf8), defaults: .default)
    }

    @Test func emptyObjectIsTheDefaultTheme() {
        let result = decode("{}")
        #expect(result.value == Theme.default)
        #expect(result.warnings.isEmpty)
    }

    @Test func missingKeysFallBackToDefaults() {
        let result = decode(##"{ "name": "Mine", "surface": { "kind": "solid" } }"##)
        #expect(result.value.name == "Mine")
        #expect(result.value.surface.kind == .solid)
        #expect(result.value.surface.opacity == Surface().opacity)
        #expect(result.value.geometry == Geometry())
        #expect(result.warnings.isEmpty)
    }

    @Test func unknownKeysAreIgnored() {
        let result = decode(##"{ "futureFeature": { "x": 1 }, "surface": { "kind": "black", "sparkles": true } }"##)
        #expect(result.value.surface.kind == .black)
        #expect(result.warnings.isEmpty)
    }

    @Test func invalidColorFallsBackOnlyForThatKey() {
        let result = decode(##"{ "colors": { "dark": { "accent": "not-a-color", "foreground": "#112233" } } }"##)
        #expect(result.value.colors.dark.accent == ColorSet.darkDefault.accent)
        #expect(result.value.colors.dark.foreground == HexColor(hex: "#112233"))
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("colors.dark.accent") == true)
    }

    @Test func unknownEnumValueFallsBack() {
        let result = decode(##"{ "surface": { "kind": "hologram" }, "motion": { "preset": "bouncy" } }"##)
        #expect(result.value.surface.kind == .black)
        #expect(result.value.motion.preset == .bouncy)
        #expect(result.warnings.count == 1)
    }

    @Test func wrongTypesFallBack() {
        let result = decode(##"{ "geometry": { "expandedWidth": "wide", "padding": 20 }, "feedback": { "haptics": "yes" } }"##)
        #expect(result.value.geometry.expandedWidth == Geometry().expandedWidth)
        #expect(result.value.geometry.padding == 20)
        #expect(result.value.feedback.haptics == Feedback().haptics)
        #expect(result.warnings.count == 2)
    }

    @Test func invalidValueInsideDictionaryIsDropped() {
        let result = decode(##"{ "providers": { "codex": { "accent": "#00FF00" }, "claude-code": { "accent": 42 } } }"##)
        #expect(result.value.providers["codex"]?.accent == HexColor(hex: "#00FF00"))
        // Only the invalid value is dropped; the entry itself stays.
        #expect(result.value.providers["claude-code"]?.accent == nil)
        #expect(!result.warnings.isEmpty)
    }

    @Test func partialSoundEntryKeepsTheRestOfTheTheme() {
        let result = decode(##"{ "name": "Mine", "feedback": { "sounds": { "agent.done": { "enabled": true } } } }"##)
        #expect(result.value.name == "Mine")
        #expect(result.value.feedback.sounds["agent.done"] == SoundSetting(enabled: true, sound: "Glass"))
    }

    @Test func partialProviderPreferencesKeepTheRestOfThePreferences() {
        let json = ##"{ "hideFromScreenCapture": false, "agentProviders": { "codex": { "approvalsEnabled": true } } }"##
        let result = TolerantDecoder.decode(Preferences.self, from: Data(json.utf8), defaults: Preferences())
        #expect(result.value.hideFromScreenCapture == false)
        #expect(result.value.agentPreferences(for: "codex").approvalsEnabled)
        #expect(result.value.agentPreferences(for: "codex").enabled)
        #expect(result.warnings.isEmpty)
    }

    @Test func requiredKeyMissingInsideDictionaryDropsOnlyThatEntry() {
        // KeyboardShortcutSpec has required keys; a broken entry must not wipe other prefs.
        let json = ##"{ "serverPort": 50000, "toggleShortcut": { "enabled": true } }"##
        let result = TolerantDecoder.decode(Preferences.self, from: Data(json.utf8), defaults: Preferences())
        #expect(result.value.serverPort == 50000)
        #expect(result.value.toggleShortcut == Preferences().toggleShortcut)
    }

    @Test func invalidJSONGivesDefaultsWithWarning() {
        let result = decode("{ nope")
        #expect(result.value == Theme.default)
        #expect(!result.warnings.isEmpty)
    }

    @Test func encodeDecodeRoundTrips() throws {
        var theme = Theme.default
        theme.id = "x"
        theme.surface.kind = .gradient
        theme.colors.light.accent = HexColor(hex: "#12345678")!
        theme.providers["codex"] = ProviderStyle(accent: .white, symbol: "terminal")
        let data = try ThemeLibrary.encode(theme)
        let back = TolerantDecoder.decode(Theme.self, from: data, defaults: .default)
        #expect(back.value == theme)
        #expect(back.warnings.isEmpty)
    }

    @Test func savedThemesStoreOnlyChangesAndRoundTrip() throws {
        var theme = Theme.default
        theme.id = "mine"
        theme.name = "Mine"
        theme.motion.preset = .bouncy
        theme.feedback.sounds["agent.permission"] = SoundSetting(enabled: false, sound: "Funk")
        theme.providers["codex"] = ProviderStyle(accent: .white)
        let data = try ThemeLibrary.encodeMinimal(theme)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Untouched sections are left out, so future default changes still apply.
        #expect(object["geometry"] == nil)
        #expect(object["surface"] == nil)
        #expect((object["motion"] as? [String: Any])?.keys.sorted() == ["preset"])
        let back = TolerantDecoder.decode(Theme.self, from: data, defaults: .default)
        #expect(back.value == theme)
        #expect(back.warnings.isEmpty)
    }

    @Test func hexColorParsing() {
        #expect(HexColor(hex: "#FFF") == .white)
        #expect(HexColor(hex: "000000") == .black)
        #expect(HexColor(hex: "#FFFFFF80")?.alpha ?? 0 > 0.49)
        #expect(HexColor(hex: "#GGGGGG") == nil)
        #expect(HexColor(hex: "#12345")  == nil)
        #expect(HexColor.white.hexString == "#FFFFFF")
    }

    @Test func fileWithoutIDTakesFileName() {
        let loaded = ThemeLibrary.decode(Data(##"{ "surface": { "kind": "solid" } }"##.utf8), fileStem: "my-cool-theme", url: URL(fileURLWithPath: "/tmp/my-cool-theme.json"))
        #expect(loaded.theme.id == "my-cool-theme")
        #expect(loaded.theme.name == "My Cool Theme")
    }

    @Test @MainActor func builtInPresetsAllDecodeCleanly() throws {
        let dir = try #require(Bundle.main.url(forResource: "Themes", withExtension: nil))
        let loaded = ThemeLibrary.loadThemes(in: dir)
        #expect(loaded.count >= 6)
        for theme in loaded {
            #expect(theme.warnings.isEmpty, "\(theme.url.lastPathComponent): \(theme.warnings)")
            #expect(theme.theme.id == theme.url.deletingPathExtension().lastPathComponent)
        }
        let ids = Set(loaded.map(\.theme.id))
        for id in ThemeLibrary.builtInIDs { #expect(ids.contains(id)) }
    }

    @Test @MainActor func libraryShadowsAndResetsBuiltIns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ThemeLibrary(directory: dir)
        var glass = try #require(library.theme(id: "glass"))
        glass.surface.opacity = 0.5
        library.save(glass)
        #expect(library.entry(id: "glass")?.isCustomized == true)
        #expect(library.theme(id: "glass")?.surface.opacity == 0.5)
        let reset = library.reset(id: "glass")
        #expect(reset.surface.opacity == 1)
        #expect(library.entry(id: "glass")?.isCustomized == false)

        let copy = library.duplicate(reset)
        #expect(copy.id == "glass-copy")
        #expect(library.entry(id: "glass-copy")?.isBuiltIn == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("glass-copy.json").path))
    }
}

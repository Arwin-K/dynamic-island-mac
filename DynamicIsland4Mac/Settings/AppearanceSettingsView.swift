import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Appearance: pick a theme, edit every key live, manage theme files.
struct AppearanceSettingsView: View {
    let services: AppServices
    @State private var editingDark = true
    @State private var errorMessage: String?

    private var store: ThemeStore { services.themeStore }
    private var library: ThemeLibrary { store.library }

    var body: some View {
        Form {
            Section {
                IslandPreviewGallery(services: services)
            }

            themeSection
            SurfaceSection(store: store)
            ColorsSection(store: store, editingDark: $editingDark)
            TypographySection(store: store)
            GeometrySection(store: store)
            MotionSection(store: store)
            IconsAndFeedbackSection(store: store)
        }
        .formStyle(.grouped)
        .onAppear { editingDark = store.isDark }
        .alert("Theme error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Theme picker and file actions

    private var themeSection: some View {
        Section("Theme") {
            Picker("Theme", selection: Binding(
                get: { store.theme.id },
                set: { store.activate(id: $0) }
            )) {
                ForEach(library.entries) { entry in
                    Text(entry.isCustomized ? "\(entry.theme.name) (customized)" : entry.theme.name).tag(entry.id)
                }
            }

            TextField("Name", text: store.binding(\.name))

            HStack {
                Button("Duplicate") {
                    store.flushPendingSave()
                    let copy = library.duplicate(store.theme)
                    store.activate(id: copy.id)
                }
                Button("Reset to Default") {
                    store.replace(with: library.reset(id: store.theme.id))
                }
                .disabled(!(library.entry(id: store.theme.id)?.isCustomized ?? false) && (library.entry(id: store.theme.id)?.isBuiltIn ?? true))
                if let entry = library.entry(id: store.theme.id), !entry.isBuiltIn {
                    Button("Delete", role: .destructive) {
                        library.delete(id: entry.id)
                        store.activate(id: library.builtIns.first?.id ?? "stealth")
                    }
                }
                Spacer()
                Button("Import…", action: importTheme)
                Button("Export…", action: exportTheme)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.themesDirectory])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show the themes folder in Finder. Edit any .json file there and the island updates live.")
                .accessibilityLabel("Show themes folder")
            }

            if let entry = library.entry(id: store.theme.id), !entry.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Some values in this theme file were invalid and were replaced by defaults:", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    ForEach(entry.warnings, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = library.lastError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text("Built-in themes can be edited freely: your changes are saved as a customized copy, and Reset to Default brings back the original.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try library.importTheme(from: url)
            store.activate(id: theme.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportTheme() {
        store.flushPendingSave()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ThemeLibrary.fileName(for: store.theme.id)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.export(store.theme, to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ThemeStore {
    /// A binding into the active theme that edits it live.
    func binding<Value>(_ keyPath: WritableKeyPath<Theme, Value>) -> Binding<Value> {
        Binding(
            get: { self.theme[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// A color binding for SwiftUI's `ColorPicker`.
    func colorBinding(_ keyPath: WritableKeyPath<Theme, HexColor>) -> Binding<Color> {
        Binding(
            get: { self.theme[keyPath: keyPath].color },
            set: { newValue in self.update { $0[keyPath: keyPath] = HexColor(newValue) } }
        )
    }
}

// MARK: - Sections

/// A slider row with a label and the current value.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 160)
                    .accessibilityLabel(title)
                    .accessibilityValue(String(format: format, value))
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct SurfaceSection: View {
    let store: ThemeStore

    var body: some View {
        Section("Surface") {
            Picker("Background", selection: store.binding(\.surface.kind)) {
                Text("Black (blends into the notch)").tag(Surface.Kind.black)
                Text("Material (blur)").tag(Surface.Kind.material)
                Text("Solid color").tag(Surface.Kind.solid)
                Text("Gradient").tag(Surface.Kind.gradient)
            }
            if store.theme.surface.kind == .material {
                Picker("Material", selection: store.binding(\.surface.material)) {
                    ForEach(Surface.MaterialKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            if store.theme.surface.kind == .gradient {
                ValueSlider(title: "Gradient angle", value: store.binding(\.surface.gradientAngle), range: 0...360, step: 5, format: "%.0f°")
            }
            ValueSlider(title: "Opacity", value: store.binding(\.surface.opacity), range: 0.2...1, step: 0.01, format: "%.2f")
            ValueSlider(title: "Border width", value: store.binding(\.surface.border.width), range: 0...4, step: 0.5, format: "%.1f")
            if store.theme.surface.border.width > 0 {
                ValueSlider(title: "Border opacity", value: store.binding(\.surface.border.opacity), range: 0...1, step: 0.05, format: "%.2f")
            }
            ValueSlider(title: "Outer shadow", value: store.binding(\.surface.shadow.outerRadius), range: 0...40)
            if store.theme.surface.shadow.outerRadius > 0 {
                ValueSlider(title: "Outer shadow opacity", value: store.binding(\.surface.shadow.outerOpacity), range: 0...1, step: 0.05, format: "%.2f")
            }
            ValueSlider(title: "Inner shadow", value: store.binding(\.surface.shadow.innerRadius), range: 0...12)
            if store.theme.surface.shadow.innerRadius > 0 {
                ValueSlider(title: "Inner shadow opacity", value: store.binding(\.surface.shadow.innerOpacity), range: 0...1, step: 0.05, format: "%.2f")
            }
        }
    }
}

private struct ColorsSection: View {
    let store: ThemeStore
    @Binding var editingDark: Bool

    var body: some View {
        let set: WritableKeyPath<Theme, ColorSet> = editingDark ? \.colors.dark : \.colors.light
        Section("Colors") {
            Picker("Appearance", selection: store.binding(\.appearance)) {
                Text("Follow system").tag(AppearanceMode.system)
                Text("Always light").tag(AppearanceMode.light)
                Text("Always dark").tag(AppearanceMode.dark)
            }
            Picker("Accent", selection: store.binding(\.colors.accentSource)) {
                Text("Fixed color").tag(Colors.AccentSource.fixed)
                Text("macOS accent color").tag(Colors.AccentSource.system)
                Text("Sample the wallpaper").tag(Colors.AccentSource.wallpaper)
                Text("Follow the album art").tag(Colors.AccentSource.albumArt)
            }
            if store.theme.colors.accentSource == .wallpaper || store.theme.colors.accentSource == .albumArt {
                Picker("Sampling", selection: store.binding(\.colors.sampleStyle)) {
                    Text("Vibrant").tag(Colors.SampleStyle.vibrant)
                    Text("Dominant").tag(Colors.SampleStyle.dominant)
                }
            }
            Picker("Editing", selection: $editingDark) {
                Text("Dark variant").tag(true)
                Text("Light variant").tag(false)
            }
            .pickerStyle(.segmented)
            ColorPicker("Foreground", selection: store.colorBinding(set.appending(path: \.foreground)), supportsOpacity: true)
            ColorPicker("Secondary", selection: store.colorBinding(set.appending(path: \.secondary)), supportsOpacity: true)
            ColorPicker(store.theme.colors.accentSource == .fixed ? "Accent" : "Accent (fallback)", selection: store.colorBinding(set.appending(path: \.accent)), supportsOpacity: false)
            ColorPicker("Surface", selection: store.colorBinding(set.appending(path: \.surface)), supportsOpacity: true)
            if store.theme.surface.kind == .gradient {
                ColorPicker("Gradient start", selection: store.colorBinding(set.appending(path: \.gradientStart)), supportsOpacity: true)
                ColorPicker("Gradient end", selection: store.colorBinding(set.appending(path: \.gradientEnd)), supportsOpacity: true)
            }
            ColorPicker("Border", selection: store.colorBinding(set.appending(path: \.border)), supportsOpacity: true)
            ColorPicker("Shadow", selection: store.colorBinding(set.appending(path: \.shadow)), supportsOpacity: true)
        }
    }
}

private struct TypographySection: View {
    let store: ThemeStore
    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Section("Typography") {
            Picker("Font", selection: store.binding(\.typography.family)) {
                ForEach(Typography.quickPicks, id: \.family) { Text($0.label).tag($0.family) }
                Divider()
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            ValueSlider(title: "Title size", value: store.binding(\.typography.titleSize), range: 9...20, step: 0.5, format: "%.1f")
            ValueSlider(title: "Body size", value: store.binding(\.typography.bodySize), range: 9...18, step: 0.5, format: "%.1f")
            ValueSlider(title: "Caption size", value: store.binding(\.typography.captionSize), range: 8...15, step: 0.5, format: "%.1f")
            Picker("Title weight", selection: store.binding(\.typography.titleWeight)) {
                ForEach(FontWeightName.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Body weight", selection: store.binding(\.typography.bodyWeight)) {
                ForEach(FontWeightName.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Monospaced digits for timers", isOn: store.binding(\.typography.monospacedDigits))
        }
    }
}

private struct GeometrySection: View {
    let store: ThemeStore

    var body: some View {
        Section("Size and Shape") {
            ValueSlider(title: "Compact side width", value: store.binding(\.geometry.compactSideWidth), range: 24...120)
            ValueSlider(title: "Expanded width", value: store.binding(\.geometry.expandedWidth), range: 300...720)
            ValueSlider(title: "Expanded height", value: store.binding(\.geometry.expandedHeight), range: 80...360)
            ValueSlider(title: "Alert width", value: store.binding(\.geometry.alertWidth), range: 240...600)
            ValueSlider(title: "Alert height", value: store.binding(\.geometry.alertHeight), range: 36...120)
            ValueSlider(title: "Collapsed corner radius", value: store.binding(\.geometry.collapsedBottomRadius), range: 0...20)
            ValueSlider(title: "Rim around the notch (sides)", value: store.binding(\.geometry.collapsedSideOutset), range: 0...30)
            ValueSlider(title: "Rim around the notch (below)", value: store.binding(\.geometry.collapsedBottomOutset), range: 0...12)
            ValueSlider(title: "Compact corner radius", value: store.binding(\.geometry.compactBottomRadius), range: 0...24)
            ValueSlider(title: "Expanded corner radius", value: store.binding(\.geometry.expandedBottomRadius), range: 0...48)
            ValueSlider(title: "Top curve depth", value: store.binding(\.geometry.topCurveDepth), range: 0...14, step: 0.5, format: "%.1f")
            ValueSlider(title: "Padding", value: store.binding(\.geometry.padding), range: 4...32)
            ValueSlider(title: "Vertical offset", value: store.binding(\.geometry.verticalOffset), range: 0...60)
            ValueSlider(title: "Pill width (no notch)", value: store.binding(\.geometry.pillWidth), range: 100...320)
            ValueSlider(title: "Pill height (no notch)", value: store.binding(\.geometry.pillHeight), range: 20...44)
        }
    }
}

private struct MotionSection: View {
    let store: ThemeStore

    var body: some View {
        Section {
            Picker("Animation", selection: store.binding(\.motion.preset)) {
                ForEach(Motion.Preset.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if store.theme.motion.preset == .custom {
                ValueSlider(title: "Response", value: store.binding(\.motion.response), range: 0.1...1.2, step: 0.01, format: "%.2f s")
                ValueSlider(title: "Damping", value: store.binding(\.motion.damping), range: 0.3...1.2, step: 0.01, format: "%.2f")
            }
            ValueSlider(title: "Hover delay", value: store.binding(\.motion.hoverDelay), range: 0...1.5, step: 0.05, format: "%.2f s")
            ValueSlider(title: "Close delay", value: store.binding(\.motion.autoCollapseDelay), range: 0...3, step: 0.05, format: "%.2f s")
            ValueSlider(title: "Alert duration", value: store.binding(\.motion.alertDuration), range: 1...15, step: 0.5, format: "%.1f s")
        } header: {
            Text("Motion")
        } footer: {
            if store.reduceMotion {
                Text("Reduce Motion is on in macOS, so springs are replaced by short fades.")
            }
        }
    }
}

private struct IconsAndFeedbackSection: View {
    let store: ThemeStore
    private static let systemSounds: [String] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Library/Sounds"), includingPropertiesForKeys: nil)) ?? []
        let names = urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        return names.isEmpty ? ["Glass", "Funk", "Ping", "Pop", "Tink"] : names
    }()

    var body: some View {
        Section("Icons") {
            Picker("Symbol weight", selection: store.binding(\.icons.weight)) {
                ForEach(FontWeightName.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Rendering", selection: store.binding(\.icons.rendering)) {
                ForEach(Icons.Rendering.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
        Section {
            Toggle("Trackpad haptics on alerts", isOn: store.binding(\.feedback.haptics))
            ForEach(FeedbackEvent.allCases, id: \.self) { event in
                SoundRow(store: store, event: event, sounds: Self.systemSounds)
            }
        } header: {
            Text("Sound and Haptics")
        } footer: {
            Text("Haptics are only felt while a finger rests on a Force Touch trackpad.")
        }
    }
}

private struct SoundRow: View {
    let store: ThemeStore
    let event: FeedbackEvent
    let sounds: [String]

    var body: some View {
        let setting = store.theme.feedback.sound(for: event)
        HStack {
            Toggle(event.label, isOn: Binding(
                get: { setting.enabled },
                set: { on in store.update { $0.feedback.sounds[event.rawValue] = SoundSetting(enabled: on, sound: setting.sound) } }
            ))
            Spacer()
            Picker("Sound", selection: Binding(
                get: { setting.sound },
                set: { name in store.update { $0.feedback.sounds[event.rawValue] = SoundSetting(enabled: setting.enabled, sound: name) } }
            )) {
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(!setting.enabled)
            Button {
                NSSound(named: NSSound.Name(setting.sound))?.play()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play \(setting.sound)")
        }
    }
}

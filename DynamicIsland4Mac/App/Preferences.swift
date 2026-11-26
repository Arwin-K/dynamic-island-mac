import Foundation
import Observation

/// Behavior settings (as opposed to looks, which live in `Theme`). Stored as readable JSON
/// in `~/Library/Application Support/DynamicIsland4Mac/preferences.json` and decoded with
/// `TolerantDecoder`, so adding a field never breaks an older file.
struct Preferences: Codable, Equatable {
    enum OpenMode: String, Codable, CaseIterable {
        case hover, click, both
        var label: String {
            switch self {
            case .hover: "Hover"
            case .click: "Click"
            case .both: "Hover or click"
            }
        }
        var opensOnHover: Bool { self != .click }
        var opensOnClick: Bool { self != .hover }
    }

    enum DisplayMode: String, Codable, CaseIterable {
        /// Only the built-in display with a notch (falls back to the main display's pill
        /// when the lid is closed).
        case builtIn
        /// Every display; displays without a notch get a floating pill.
        case all
        /// One display, chosen by name.
        case chosen
        var label: String {
            switch self {
            case .builtIn: "Built-in display only"
            case .all: "All displays"
            case .chosen: "A chosen display"
            }
        }
    }

    var activeThemeID: String = "stealth"
    var openMode: OpenMode = .hover
    var closeOnMouseExit: Bool = true
    var displayMode: DisplayMode = .builtIn
    var chosenDisplayName: String = ""
    var hideInFullScreen: Bool = true
    /// Sets `NSWindow.sharingType = .none`, so the island never appears in screen sharing,
    /// screenshots or recordings.
    var hideFromScreenCapture: Bool = true
    /// Hides the floating pill on displays without a notch when nothing is active.
    var hideWhenIdle: Bool = false
    var showMenuBarItem: Bool = true
    var toggleShortcut = KeyboardShortcutSpec.defaultToggle

    // Modules
    /// Module ids in the user's priority order. Modules not listed fall back to their default priority.
    var moduleOrder: [String] = []
    /// Explicit on/off per module id. Missing = the module's `enabledByDefault`.
    var moduleEnabled: [String: Bool] = [:]
    /// Per-module settings, keyed by module id, then by setting name. Modules read these
    /// through `ModuleContext` so they don't need their own persistence.
    var moduleSettings: [String: [String: String]] = [:]

    // Agents
    var serverPort: Int = 47_829
    var agentStaleTimeoutMinutes: Double = 30
    var agentGroupByProvider: Bool = false
    var agentShowTokenUsage: Bool = false
    var agentProviders: [String: AgentProviderPreferences] = [:]
    /// When each provider last delivered an event (seconds since 1970).
    var agentLastEventAt: [String: Double] = [:]
    /// Optional override for `$CODEX_HOME` (apps launched from Finder don't see shell variables).
    var codexHomeOverride: String = ""

    func agentPreferences(for providerID: String) -> AgentProviderPreferences {
        agentProviders[providerID] ?? AgentProviderPreferences()
    }
}

struct AgentProviderPreferences: Codable, Equatable {
    var enabled: Bool = true
    var alertOnPermission: Bool = true
    var alertOnIdle: Bool = true
    var alertOnDone: Bool = true
    var alertOnFailure: Bool = true
    /// Opt-in: show Allow / Deny in the island and answer the agent's PermissionRequest hook.
    var approvalsEnabled: Bool = false
    var approvalTimeoutSeconds: Double = 45

    init() {}

    /// Lives inside a dictionary, where `TolerantDecoder` can't supply per-key defaults, so
    /// missing keys are filled here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentProviderPreferences()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        alertOnPermission = (try? c.decodeIfPresent(Bool.self, forKey: .alertOnPermission)) ?? d.alertOnPermission
        alertOnIdle = (try? c.decodeIfPresent(Bool.self, forKey: .alertOnIdle)) ?? d.alertOnIdle
        alertOnDone = (try? c.decodeIfPresent(Bool.self, forKey: .alertOnDone)) ?? d.alertOnDone
        alertOnFailure = (try? c.decodeIfPresent(Bool.self, forKey: .alertOnFailure)) ?? d.alertOnFailure
        approvalsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .approvalsEnabled)) ?? d.approvalsEnabled
        approvalTimeoutSeconds = (try? c.decodeIfPresent(Double.self, forKey: .approvalTimeoutSeconds)) ?? d.approvalTimeoutSeconds
    }
}

/// A global shortcut, stored as a Carbon virtual key code plus modifier flags.
struct KeyboardShortcutSpec: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags.rawValue`, masked to command/option/control/shift.
    var modifiers: UInt
    var enabled: Bool = true

    /// ⌃⌥I
    static let defaultToggle = KeyboardShortcutSpec(keyCode: 34, modifiers: (1 << 18) | (1 << 19))
}

/// Owns the current `Preferences` and writes changes back to disk (debounced).
@MainActor
@Observable
final class PreferencesStore {
    var values: Preferences {
        didSet { if values != oldValue { scheduleSave() } }
    }
    private(set) var warnings: [String] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL?

    /// - Parameter fileURL: `nil` keeps preferences in memory only (tests, previews).
    init(fileURL: URL? = AppPaths.isRunningTests ? nil : AppPaths.preferencesFile) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let result = TolerantDecoder.decode(Preferences.self, from: data, defaults: Preferences())
            values = result.value
            warnings = result.warnings
            result.warnings.forEach { Log.app.warning("preferences: \($0, privacy: .public)") }
        } else {
            values = Preferences()
        }
    }

    /// Change preferences, notifying observers only if something actually changed.
    /// Prefer this to assigning `values` directly from code that may run during view updates.
    func update(_ change: (inout Preferences) -> Void) {
        var next = values
        change(&next)
        if next != values { values = next }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(values).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Could not save preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}

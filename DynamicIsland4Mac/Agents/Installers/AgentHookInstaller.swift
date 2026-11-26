import Foundation

/// Installs and removes a provider's hooks. Every installer follows the same safety rules:
/// show the exact diff and ask first, back up the original, merge (never overwrite), tag our
/// entries so Disconnect removes exactly those, and refuse to write if the file changed
/// after the diff was shown.
@MainActor
protocol AgentHookInstaller: AnyObject {
    var providerID: String { get }
    /// The file the installer edits.
    var fileURL: URL { get }
    func status(lastEventAt: Date?) -> InstallStatus
    /// - Parameter approvalTimeout: when set, also installs the synchronous PermissionRequest
    ///   hook used by island approvals, waiting this many seconds for a decision.
    func planInstall(approvalTimeout: Int?) throws -> InstallPlan
    func planUninstall() throws -> InstallPlan
    func apply(_ plan: InstallPlan) throws
    /// What to paste for people who'd rather edit the file themselves.
    func manualSnippet(approvalTimeout: Int?) -> String
    /// Shown after installing (Codex: the trust step).
    var postInstallNote: String? { get }
}

enum InstallStatus: Equatable {
    case notInstalled
    /// Installed; no event has arrived since.
    case installed
    /// Codex: installed, but the hooks must be reviewed and trusted in Codex before they run.
    case needsTrust
    case receivingEvents
    /// Installed, but different from what this version would install (e.g. approvals toggled).
    case outdated
    /// Codex: hooks are declared inline in config.toml, so hooks.json must not be written.
    case manualTOML
    case error(String)

    var label: String {
        switch self {
        case .notInstalled: "Not connected"
        case .installed: "Connected, waiting for the first event"
        case .needsTrust: "Installed, needs trust in Codex"
        case .receivingEvents: "Receiving events"
        case .outdated: "Connected, update available"
        case .manualTOML: "Uses config.toml hooks: add them manually"
        case .error(let message): message
        }
    }

    var isInstalled: Bool {
        switch self {
        case .installed, .needsTrust, .receivingEvents, .outdated: true
        default: false
        }
    }
}

struct InstallPlan: Equatable {
    var fileURL: URL
    /// The file's text when the plan was made (`nil` if it didn't exist).
    var originalText: String?
    /// The text to write (`nil` = delete the file, used when we created it and it's empty again).
    var newText: String?
    var record: HookMerger.Record
    var isUninstall: Bool

    var diff: [LineDiff.Line] { LineDiff.condensed(LineDiff.diff(originalText ?? "", newText ?? "")) }
    var changesNothing: Bool { originalText == newText }
}

/// Shared implementation for providers whose hooks live in a JSON file with the
/// `{"hooks": {...}}` layout (Claude Code `settings.json`, Codex `hooks.json`).
@MainActor
class JSONHookInstaller: AgentHookInstaller {
    let providerID: String
    let events: [String]
    var fileURL: URL { fatalError("Subclasses provide fileURL") }
    var postInstallNote: String? { nil }

    init(providerID: String, events: [String]) {
        self.providerID = providerID
        self.events = events
    }

    // MARK: Entries

    /// `"<…>/agent-hook.sh" <provider>`. The path is quoted because it contains a space
    /// ("Application Support"). It is the same on every launch, so installed entries stay
    /// stable across app updates.
    var baseCommand: String { "\"\(AppPaths.installedHookScript.path)\" \(providerID)" }

    func entries(approvalTimeout: Int?) -> [HookMerger.Entry] {
        var entries = events.map { HookMerger.Entry(event: $0, command: baseCommand, async: true) }
        if let approvalTimeout {
            // Synchronous on purpose: the agent waits for the island's answer, up to the
            // timeout. The hook's own timeout is longer, so the script always finishes first
            // and exits 0 with no output (= no decision) rather than being killed.
            entries.append(HookMerger.Entry(event: "PermissionRequest", command: "\(baseCommand) permission \(approvalTimeout)",
                                            async: false, timeout: approvalTimeout + 15))
        }
        return entries
    }

    // MARK: Record of what merge created

    /// Where the install record lives (overridden in tests).
    var recordDirectory: URL { AppPaths.supportDirectory }
    private var recordURL: URL { recordDirectory.appendingPathComponent("install-\(providerID).json") }

    struct StoredRecord: Codable {
        var record: HookMerger.Record
        var installedAt: Date
        var file: String
    }

    func storedRecord() -> StoredRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredRecord.self, from: data)
    }

    private func saveRecord(_ record: HookMerger.Record?) {
        guard let record else { try? FileManager.default.removeItem(at: recordURL); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = StoredRecord(record: record, installedAt: Date(), file: fileURL.path)
        try? encoder.encode(stored).write(to: recordURL, options: .atomic)
    }

    // MARK: Reading

    func readFile() throws -> (text: String?, root: JSONValue) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (nil, .object([])) }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, .object([])) }
        return (text, try OrderedJSON.parse(text))
    }

    func status(lastEventAt: Date?) -> InstallStatus {
        let root: JSONValue
        do { root = try readFile().root } catch { return .error("Can't read \(fileURL.lastPathComponent): \(error.localizedDescription)") }
        let installed = HookMerger.ourCommands(root)
        guard !installed.isEmpty else { return .notInstalled }
        // Compare with what we'd install now (with or without the approval entry).
        let wanted = Set(entries(approvalTimeout: nil).map(\.command))
        if !wanted.isSubset(of: Set(installed.values.flatMap { $0 })) { return .outdated }
        let installedAt = storedRecord()?.installedAt ?? .distantPast
        if let lastEventAt, lastEventAt > installedAt { return .receivingEvents }
        return awaitingFirstEventStatus
    }

    var awaitingFirstEventStatus: InstallStatus { .installed }

    /// Whether the synchronous approval entry is installed (with any timeout).
    func approvalEntryInstalled() -> Bool {
        guard let root = try? readFile().root else { return false }
        return HookMerger.ourCommands(root)["PermissionRequest"]?.contains { $0.contains(" permission ") } ?? false
    }

    // MARK: Planning

    func planInstall(approvalTimeout: Int?) throws -> InstallPlan {
        let (text, root) = try readFile()
        // Start from a clean slate of our own entries, so toggling approvals or changing the
        // timeout replaces rather than duplicates them.
        let previous = storedRecord()?.record
        let cleaned = HookMerger.unmerge(root, record: previous)
        var startRecord = previous ?? HookMerger.Record()
        if text == nil { startRecord.createdFile = true }
        let (merged, record) = try HookMerger.merge(cleaned, entries: entries(approvalTimeout: approvalTimeout), record: startRecord)
        let indent = text.flatMap(OrderedJSON.detectIndent) ?? "  "
        return InstallPlan(fileURL: fileURL, originalText: text, newText: OrderedJSON.print(merged, indent: indent),
                           record: record, isUninstall: false)
    }

    func planUninstall() throws -> InstallPlan {
        let (text, root) = try readFile()
        let record = storedRecord()?.record
        let cleaned = HookMerger.unmerge(root, record: record)
        let indent = text.flatMap(OrderedJSON.detectIndent) ?? "  "
        var newText: String? = OrderedJSON.print(cleaned, indent: indent)
        if record?.createdFile == true, cleaned == .object([]) { newText = nil }
        if !HookMerger.containsOurEntries(root) { newText = text }
        return InstallPlan(fileURL: fileURL, originalText: text, newText: newText, record: record ?? HookMerger.Record(), isUninstall: true)
    }

    // MARK: Writing

    enum ApplyError: LocalizedError {
        case changedSincePlanned
        var errorDescription: String? {
            "The file changed since the diff was shown. Nothing was written; review the changes again."
        }
    }

    func apply(_ plan: InstallPlan) throws {
        let fm = FileManager.default
        let current = fm.fileExists(atPath: plan.fileURL.path) ? try String(contentsOf: plan.fileURL, encoding: .utf8) : nil
        guard current == plan.originalText else { throw ApplyError.changedSincePlanned }
        guard !plan.changesNothing else { return }

        // Back up the original first.
        if let original = plan.originalText {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let backup = plan.fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(plan.fileURL.lastPathComponent).dynamicisland4mac-backup-\(formatter.string(from: Date()))")
            try original.write(to: backup, atomically: true, encoding: .utf8)
            Log.installer.info("Backed up \(plan.fileURL.path, privacy: .public) to \(backup.lastPathComponent, privacy: .public)")
        }

        if let newText = plan.newText {
            try fm.createDirectory(at: plan.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = (try? fm.attributesOfItem(atPath: plan.fileURL.path)[.posixPermissions]) as? NSNumber
            try newText.write(to: plan.fileURL, atomically: true, encoding: .utf8)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: plan.fileURL.path) }
        } else {
            try fm.removeItem(at: plan.fileURL)
        }
        saveRecord(plan.isUninstall ? nil : plan.record)
        Log.installer.info("\(plan.isUninstall ? "Removed" : "Installed", privacy: .public) \(self.providerID, privacy: .public) hooks in \(plan.fileURL.path, privacy: .public)")
    }

    // MARK: Manual setup

    func manualSnippet(approvalTimeout: Int?) -> String {
        let (merged, _) = (try? HookMerger.merge(.object([]), entries: entries(approvalTimeout: approvalTimeout))) ?? (.object([]), HookMerger.Record())
        return OrderedJSON.print(merged)
    }
}

/// Claude Code: merges into `~/.claude/settings.json` under `"hooks"`.
@MainActor
final class ClaudeCodeInstaller: JSONHookInstaller {
    init(provider: ClaudeCodeProvider) {
        super.init(providerID: provider.id, events: ClaudeCodeProvider.observedEvents)
    }

    override var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    override var postInstallNote: String? {
        "Hooks load when a Claude Code session starts: restart running sessions (or run /hooks in Claude Code to check them). In a new folder, Claude Code only runs hooks after you accept its workspace trust dialog."
    }
}

/// Codex: writes `$CODEX_HOME/hooks.json` (default `~/.codex`). If `config.toml` already
/// declares `[hooks]` inline, Codex warns when one layer uses both formats, so we don't
/// write hooks.json and show the TOML to paste instead.
@MainActor
final class CodexInstaller: JSONHookInstaller {
    private(set) var codexHome: URL

    init(provider: CodexProvider) {
        codexHome = CodexHome.resolveQuickly()
        super.init(providerID: provider.id, events: CodexProvider.observedEvents)
    }

    override var fileURL: URL { codexHome.appendingPathComponent("hooks.json") }
    var configTOMLURL: URL { codexHome.appendingPathComponent("config.toml") }

    func setCodexHome(_ url: URL) { codexHome = url }

    override var postInstallNote: String? {
        "Codex only runs new or changed hooks after you trust them. In the Codex CLI run /hooks and trust the DynamicIsland4Mac entries (in the Codex app: Settings → Hooks, or \"Review hooks\" in the composer). Status changes to \"Receiving events\" after the first event."
    }

    override var awaitingFirstEventStatus: InstallStatus { .needsTrust }

    /// True when config.toml has inline `[hooks…]` tables.
    var configUsesInlineHooks: Bool {
        guard let text = try? String(contentsOf: configTOMLURL, encoding: .utf8) else { return false }
        return Self.tomlDeclaresHooks(text)
    }

    nonisolated static func tomlDeclaresHooks(_ toml: String) -> Bool {
        for rawLine in toml.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // [hooks], [hooks.X], [[hooks.X]], [[hooks.X.hooks]]
            if line.range(of: #"^\[\[?\s*hooks\s*(\.|\]|$)"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    override func status(lastEventAt: Date?) -> InstallStatus {
        if configUsesInlineHooks && !FileManager.default.fileExists(atPath: fileURL.path) {
            if let lastEventAt, lastEventAt > Date().addingTimeInterval(-7 * 24 * 3600) { return .receivingEvents }
            return .manualTOML
        }
        return super.status(lastEventAt: lastEventAt)
    }

    override func planInstall(approvalTimeout: Int?) throws -> InstallPlan {
        if configUsesInlineHooks { throw CodexError.inlineTOMLHooks }
        return try super.planInstall(approvalTimeout: approvalTimeout)
    }

    enum CodexError: LocalizedError {
        case inlineTOMLHooks
        var errorDescription: String? {
            "Your config.toml already declares hooks inline. Codex warns when hooks.json and config.toml hooks are mixed, so add the TOML below to config.toml instead."
        }
    }

    /// The same entries as `[[hooks.<Event>]]` tables, for config.toml users.
    func tomlSnippet(approvalTimeout: Int?) -> String {
        var out = "# DynamicIsland4Mac hooks\n"
        for entry in entries(approvalTimeout: approvalTimeout) {
            out += "\n[[hooks.\(entry.event)]]\n"
            if let matcher = entry.matcher { out += "matcher = \"\(matcher)\"\n" }
            out += "[[hooks.\(entry.event).hooks]]\n"
            out += "type = \"command\"\n"
            // A TOML literal string (single quotes) keeps the inner double quotes as-is.
            out += "command = '\(entry.command)'\n"
            if entry.async { out += "async = true\n" }
            if let timeout = entry.timeout { out += "timeout = \(timeout)\n" }
        }
        return out
    }
}

/// Finds `$CODEX_HOME`. Apps launched from Finder don't inherit shell variables, so besides
/// our own environment we check launchd and (in the background) a login shell.
enum CodexHome {
    static var defaultURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex") }

    @MainActor
    static func resolveQuickly() -> URL {
        let override = AppServices.shared.preferences.values.codexHomeOverride
        if !override.isEmpty { return URL(fileURLWithPath: (override as NSString).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return defaultURL
    }

    /// Slower: asks launchd and the user's login shell. Call off the main thread.
    static func resolveFromShell() -> URL? {
        for (exe, args) in [("/bin/launchctl", ["getenv", "CODEX_HOME"]),
                            (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", ["-lc", "printf %s \"$CODEX_HOME\""])] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); continue }
            let value = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
        }
        return nil
    }
}

import Foundation
import os

/// One `Logger` per area, all under the app's bundle identifier as the subsystem.
///
/// To collect logs for a bug report:
///
///     log stream --predicate 'subsystem == "com.dynamicisland4mac.DynamicIsland4Mac"' --level debug
///
/// or filter by category (for example `category == "agents"`) in Console.app.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.dynamicisland4mac.DynamicIsland4Mac"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let theme = Logger(subsystem: subsystem, category: "theme")
    static let modules = Logger(subsystem: subsystem, category: "modules")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let agents = Logger(subsystem: subsystem, category: "agents")
    static let installer = Logger(subsystem: subsystem, category: "installer")
    static let battery = Logger(subsystem: subsystem, category: "battery")
    static let hud = Logger(subsystem: subsystem, category: "hud")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
}

/// Shared filesystem locations. Everything the app writes lives under Application Support.
enum AppPaths {
    static let folderName = "DynamicIsland4Mac"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var themesDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var preferencesFile: URL { supportDirectory.appendingPathComponent("preferences.json") }
    static var tokenFile: URL { supportDirectory.appendingPathComponent("token") }
    static var portFile: URL { supportDirectory.appendingPathComponent("port") }
    static var installedHookScript: URL { supportDirectory.appendingPathComponent("agent-hook.sh") }

    /// True when the process is hosting unit tests. The app skips creating windows,
    /// servers and event taps in that case so tests stay fast and side-effect free.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

import AppKit

/// Brings an agent session's terminal tab (or app) to the front.
///
/// What works where (also in the README):
///
/// | Where the session runs | How | Precision |
/// |---|---|---|
/// | Terminal.app | AppleScript: the tab whose `tty` matches | exact tab |
/// | iTerm2 | AppleScript: the session whose `unique id` (from `$ITERM_SESSION_ID`) or `tty` matches | exact tab/pane |
/// | VS Code / Cursor | `vscode://file/<cwd>` / `cursor://file/<cwd>` | the window for that folder |
/// | Ghostty, Warp | activate the app | app only (no scripting API for tabs) |
/// | Codex desktop app | activate the app | app only |
/// | Anything else | activate the app that launched the shell (`$__CFBundleIdentifier`) | app only |
///
/// AppleScript runs in `osascript` off the main thread; the first use asks for Automation
/// permission for that terminal.
@MainActor
enum TerminalFocuser {
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    static let vscodeBundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]

    static func focus(_ session: AgentSession) {
        let t = session.terminal
        let tty = t.tty.map { $0.hasPrefix("/dev/") ? $0 : "/dev/\($0)" }

        switch t.termProgram {
        case "Apple_Terminal":
            if let tty { runFocusScript(terminalScript(tty: tty), fallback: session); return }
        case "iTerm.app":
            let uniqueID = t.itermSessionID?.split(separator: ":").last.map(String.init)
            if uniqueID != nil || tty != nil { runFocusScript(itermScript(uniqueID: uniqueID, tty: tty), fallback: session); return }
        case "vscode":
            // VS Code and Cursor both report "vscode"; the launching app's bundle id tells them apart.
            let scheme = t.bundleID == cursorBundleID ? "cursor" : (t.bundleID == "com.microsoft.VSCodeInsiders" ? "vscode-insiders" : "vscode")
            if let cwd = session.cwd, let url = URL(string: "\(scheme)://file\(cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd)") {
                NSWorkspace.shared.open(url)
                return
            }
        default:
            break
        }
        AgentAppActivator.activate(session)
    }

    private static func runFocusScript(_ script: String, fallback session: AgentSession) {
        Task.detached(priority: .userInitiated) {
            let result = AppleScriptMediaSource.osascript(script)
            if result != "ok" {
                await MainActor.run { AgentAppActivator.activate(session) }
            }
        }
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static func itermScript(uniqueID: String?, tty: String?) -> String {
        let condition: String
        switch (uniqueID, tty) {
        case let (id?, tty?): condition = "(unique id of s is \"\(escape(id))\") or (tty of s is \"\(escape(tty))\")"
        case let (id?, nil): condition = "unique id of s is \"\(escape(id))\""
        case let (nil, tty?): condition = "tty of s is \"\(escape(tty))\""
        default: condition = "false"
        }
        return """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if \(condition) then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

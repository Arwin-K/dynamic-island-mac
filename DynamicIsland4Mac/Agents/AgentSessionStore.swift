import Foundation
import Observation

/// Every running agent session on this Mac, from every provider, keyed by (provider, session id).
@MainActor
@Observable
final class AgentSessionStore {
    private(set) var sessions: [String: AgentSession] = [:]
    /// Called for each notable transition (permission needed, finished…), for alerts.
    @ObservationIgnored var onTransition: ((AgentSession, AgentSessionReducer.Transition) -> Void)?
    /// Minutes without events before a session is marked stale.
    @ObservationIgnored var staleTimeoutMinutes: Double = 30

    @ObservationIgnored private var sweepTimer: Timer?

    /// Sessions sorted for display: needing the user first, then most recently active.
    var sorted: [AgentSession] {
        sessions.values.sorted {
            if $0.state.urgency != $1.state.urgency { return $0.state.urgency < $1.state.urgency }
            return $0.lastUpdate > $1.lastUpdate
        }
    }

    var needingUser: [AgentSession] { sorted.filter { $0.state.needsUser } }

    func apply(_ event: AgentEvent) {
        let key = AgentSession.key(provider: event.provider, sessionID: event.sessionID)
        let existing = sessions[key]
        let result = AgentSessionReducer.reduce(existing, event)
        if let session = result.session {
            sessions[key] = session
            if existing?.cwd != session.cwd { lookUpGitBranch(for: key, cwd: session.cwd) }
            if case .stopped(let message) = event.kind, message == nil, let path = session.transcriptPath {
                loadLastMessage(for: key, transcript: path)
            }
            for transition in result.transitions { onTransition?(session, transition) }
        } else {
            if let existing { for t in result.transitions { onTransition?(existing, t) } }
            sessions.removeValue(forKey: key)
        }
        updateSweepTimer()
    }

    /// Settings preview only.
    func insertForPreview(_ session: AgentSession) {
        sessions[session.id] = session
    }

    func remove(_ id: String) {
        sessions.removeValue(forKey: id)
        updateSweepTimer()
    }

    func removeAll(where shouldRemove: (AgentSession) -> Bool) {
        sessions = sessions.filter { !shouldRemove($0.value) }
        updateSweepTimer()
    }

    // MARK: - Stale sessions

    /// The sweep timer only exists while there are sessions, so an idle app does no work.
    private func updateSweepTimer() {
        if sessions.isEmpty {
            sweepTimer?.invalidate()
            sweepTimer = nil
        } else if sweepTimer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
            timer.tolerance = 15
            RunLoop.main.add(timer, forMode: .common)
            sweepTimer = timer
        }
    }

    func sweep(now: Date = Date()) {
        let timeout = staleTimeoutMinutes * 60
        for (key, var session) in sessions {
            let idle = now.timeIntervalSince(session.lastUpdate)
            // The agent process is gone (both candidate pids dead): the session ended without
            // a SessionEnd (crash, killed terminal).
            if Self.processesGone(session.terminal), idle > 5 {
                sessions.removeValue(forKey: key)
                continue
            }
            if idle > timeout * 3 {
                sessions.removeValue(forKey: key)
            } else if idle > timeout, !session.isStale {
                session.isStale = true
                sessions[key] = session
            }
        }
        updateSweepTimer()
    }

    private static func processesGone(_ terminal: AgentTerminalInfo) -> Bool {
        let pids = [terminal.parentPID, terminal.grandparentPID].compactMap { $0 }.filter { $0 > 1 }
        guard !pids.isEmpty else { return false }
        return pids.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
    }

    // MARK: - Enrichment (off the main thread)

    private func lookUpGitBranch(for key: String, cwd: String?) {
        guard let cwd else { return }
        Task.detached(priority: .utility) {
            let branch = GitInfo.branch(at: cwd)
            await MainActor.run { [weak self] in
                guard var session = self?.sessions[key], session.cwd == cwd else { return }
                session.gitBranch = branch
                self?.sessions[key] = session
            }
        }
    }

    private func loadLastMessage(for key: String, transcript path: String) {
        Task.detached(priority: .utility) {
            guard let message = TranscriptReader.lastAssistantMessage(transcriptPath: path) else { return }
            await MainActor.run { [weak self] in
                guard var session = self?.sessions[key] else { return }
                session.lastAssistantMessage = message
                self?.sessions[key] = session
            }
        }
    }
}

/// Reads the current branch straight from `.git/HEAD` (no `git` process).
enum GitInfo {
    static func branch(at path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<12 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                var headURL = git.appendingPathComponent("HEAD")
                if !isDir.boolValue, let pointer = try? String(contentsOf: git, encoding: .utf8),
                   pointer.hasPrefix("gitdir:") {
                    // Worktrees and submodules: `.git` is a file pointing at the real git dir.
                    let target = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    headURL = URL(fileURLWithPath: target, relativeTo: dir).appendingPathComponent("HEAD")
                }
                guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
                return String(trimmed.prefix(7)) // detached HEAD
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

/// Reads only the end of a Claude Code transcript (JSONL) to find the last assistant text.
/// Used when a Stop event arrives without `last_assistant_message`.
enum TranscriptReader {
    static func lastAssistantMessage(transcriptPath: String, tailBytes: Int = 128 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String, !text.isEmpty { return ToolSummary.truncate(text, to: 400) }
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                if !text.isEmpty { return ToolSummary.truncate(text, to: 400) }
            }
        }
        return nil
    }
}

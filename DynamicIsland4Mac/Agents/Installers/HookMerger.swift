import Foundation

/// Adds and removes our hook entries in a Claude Code `settings.json` or Codex `hooks.json`
/// (both use `{"hooks": {"<Event>": [{"matcher"?, "hooks": [handler…]}]}}`).
///
/// Rules (pure functions, unit tested for exact round trips):
/// * **Merge, never overwrite**: existing keys, events, groups and handlers are left exactly
///   where they are; ours are appended at the end.
/// * **Tagged**: our handlers are recognized by their command, which contains the path of our
///   hook script (`HookMerger.tag`). Nothing else is ever removed.
/// * **Exact undo**: `unmerge` uses the `Record` from `merge` to also remove the `hooks` key or
///   event arrays that merge had to create, so merge → unmerge gives back the original.
/// * **Idempotent**: merging twice adds nothing the second time.
enum HookMerger {
    /// Every command we install contains this.
    static let tag = "DynamicIsland4Mac/agent-hook.sh"

    struct Entry: Equatable {
        var event: String
        var command: String
        var async: Bool
        var timeout: Int?
        var matcher: String?

        var handler: JSONValue {
            var members: [JSONValue.Member] = [
                .init(key: "type", value: .string("command")),
                .init(key: "command", value: .string(command)),
            ]
            if async { members.append(.init(key: "async", value: .bool(true))) }
            if let timeout { members.append(.init(key: "timeout", value: .number(String(timeout)))) }
            return .object(members)
        }

        var group: JSONValue {
            var members: [JSONValue.Member] = []
            if let matcher { members.append(.init(key: "matcher", value: .string(matcher))) }
            members.append(.init(key: "hooks", value: .array([handler])))
            return .object(members)
        }
    }

    /// What `merge` had to create, so `unmerge` can remove exactly that. Stored next to the
    /// backup in Application Support.
    struct Record: Codable, Equatable {
        var createdHooksKey = false
        var createdEvents: [String] = []
        var createdFile = false
    }

    enum MergeError: LocalizedError {
        case notAnObject(String)
        var errorDescription: String? {
            switch self {
            case .notAnObject(let what): "\(what) isn't a JSON object, so it can't be merged safely. Fix or move the file, then try again."
            }
        }
    }

    static func isOurs(_ handler: JSONValue) -> Bool {
        handler["command"]?.stringValue?.contains(tag) ?? false
    }

    static func containsOurEntries(_ root: JSONValue) -> Bool {
        guard let events = root["hooks"]?.objectMembers else { return false }
        return events.contains { event in
            (event.value.arrayValue ?? []).contains { group in (group["hooks"]?.arrayValue ?? []).contains(where: isOurs) }
        }
    }

    /// The commands of our installed handlers, keyed by event (for status checks).
    static func ourCommands(_ root: JSONValue) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for event in root["hooks"]?.objectMembers ?? [] {
            for group in event.value.arrayValue ?? [] {
                for handler in group["hooks"]?.arrayValue ?? [] where isOurs(handler) {
                    if let c = handler["command"]?.stringValue { result[event.key, default: []].append(c) }
                }
            }
        }
        return result
    }

    static func merge(_ root: JSONValue, entries: [Entry], record: Record = Record()) throws -> (JSONValue, Record) {
        guard case .object = root else { throw MergeError.notAnObject("The settings file") }
        var root = root
        var record = record
        var hooks: JSONValue
        if let existing = root["hooks"] {
            guard case .object = existing else { throw MergeError.notAnObject("Its \"hooks\" value") }
            hooks = existing
        } else {
            hooks = .object([])
            record.createdHooksKey = true
        }

        for entry in entries {
            var groups: [JSONValue]
            if let existing = hooks[entry.event] {
                guard let array = existing.arrayValue else { throw MergeError.notAnObject("hooks.\(entry.event)") }
                groups = array
            } else {
                groups = []
                if !record.createdEvents.contains(entry.event) { record.createdEvents.append(entry.event) }
            }
            let alreadyThere = groups.contains { group in
                (group["hooks"]?.arrayValue ?? []).contains { $0 == entry.handler }
            }
            if !alreadyThere { groups.append(entry.group) }
            hooks.set(entry.event, .array(groups))
        }
        root.set("hooks", hooks)
        return (root, record)
    }

    /// Removes every handler we added (and only those). Groups and events that become empty
    /// because of that are removed; the `hooks` key and events merge created are removed when
    /// empty. Without a record, empty containers we emptied are removed.
    static func unmerge(_ root: JSONValue, record: Record?) -> JSONValue {
        guard case .object = root, let hooks = root["hooks"], case .object(let events) = hooks else { return root }
        var root = root
        var newEvents: [JSONValue.Member] = []
        var touchedAny = false
        for event in events {
            guard let groups = event.value.arrayValue else { newEvents.append(event); continue }
            var newGroups: [JSONValue] = []
            var touchedEvent = false
            for group in groups {
                guard case .object = group, let handlers = group["hooks"]?.arrayValue else { newGroups.append(group); continue }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count { newGroups.append(group); continue }
                touchedEvent = true
                if !kept.isEmpty {
                    var g = group
                    g.set("hooks", .array(kept))
                    newGroups.append(g)
                }
            }
            touchedAny = touchedAny || touchedEvent
            let removeEvent = newGroups.isEmpty && touchedEvent && (record.map { $0.createdEvents.contains(event.key) } ?? true)
            if !removeEvent { newEvents.append(JSONValue.Member(key: event.key, value: .array(newGroups))) }
        }
        if newEvents.isEmpty && touchedAny && (record?.createdHooksKey ?? true) {
            root.remove("hooks")
        } else {
            root.set("hooks", .object(newEvents))
        }
        return root
    }
}

/// A minimal line diff (LCS) for showing the user exactly what an installer will change.
enum LineDiff {
    enum Line: Equatable {
        case same(String)
        case added(String)
        case removed(String)
    }

    static func diff(_ old: String, _ new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        // Lengths of the longest common subsequence of suffixes.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { result.append(.same(a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { result.append(.removed(a[i])); i += 1 }
            else { result.append(.added(b[j])); j += 1 }
        }
        while i < n { result.append(.removed(a[i])); i += 1 }
        while j < m { result.append(.added(b[j])); j += 1 }
        return result
    }

    /// Only changed lines plus `context` lines around them, with "…" for skipped runs.
    static func condensed(_ lines: [Line], context: Int = 3) -> [Line] {
        let changed = lines.indices.filter { if case .same = lines[$0] { false } else { true } }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed { for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) } }
        var result: [Line] = []
        var last = -1
        for index in keep.sorted() {
            if last >= 0, index > last + 1 { result.append(.same("…")) }
            result.append(lines[index])
            last = index
        }
        return result
    }
}

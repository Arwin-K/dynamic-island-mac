import Foundation
import Testing
@testable import DynamicIsland4Mac

struct OrderedJSONTests {
    @Test func canonicalTextRoundTripsByteForByte() throws {
        let text = """
        {
          "zeta": 1,
          "alpha": {
            "list": [
              1.50,
              -2e10,
              true,
              null,
              "é ✓ \\"quoted\\" \\\\ \\n"
            ],
            "empty": {},
            "none": []
          },
          "permissions": {
            "allow": [
              "Bash(git *)"
            ]
          }
        }

        """
        let value = try OrderedJSON.parse(text)
        #expect(OrderedJSON.print(value) == text)
    }

    @Test func keepsKeyOrderAndNumbersExactly() throws {
        let value = try OrderedJSON.parse(#"{"b":1.0,"a":10e2}"#)
        #expect(value.objectMembers?.map(\.key) == ["b", "a"])
        #expect(value["b"] == .number("1.0"))
        #expect(value["a"] == .number("10e2"))
    }

    @Test func unicodeEscapesAndSurrogates() throws {
        let value = try OrderedJSON.parse(#"{"s":"é😀"}"#)
        #expect(value["s"]?.stringValue == "é😀")
    }

    @Test func detectsIndent() {
        #expect(OrderedJSON.detectIndent("{\n    \"a\": 1\n}") == "    ")
        #expect(OrderedJSON.detectIndent("{\n\t\"a\": 1\n}") == "\t")
        #expect(OrderedJSON.detectIndent("{}") == nil)
    }

    @Test func rejectsInvalid() {
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse("{\"a\":}") }
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse("{} trailing") }
    }
}

struct HookMergerTests {
    let ours = "\"/Users/me/Library/Application Support/DynamicIsland4Mac/agent-hook.sh\" claude-code"
    var entries: [HookMerger.Entry] {
        ["PreToolUse", "Stop", "SessionEnd"].map { HookMerger.Entry(event: $0, command: ours, async: true) }
    }

    /// A realistic settings.json with the user's own hooks and other settings.
    let userSettings = """
    {
      "model": "opus",
      "permissions": {
        "allow": [
          "Bash(npm test)"
        ]
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/bin/guard.sh",
                "timeout": 30
              }
            ]
          }
        ],
        "Notification": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "~/bin/status.sh"
      }
    }

    """

    @Test func mergeKeepsEverythingAndAppends() throws {
        let original = try OrderedJSON.parse(userSettings)
        let (merged, record) = try HookMerger.merge(original, entries: entries)
        // Top-level order untouched.
        #expect(merged.objectMembers?.map(\.key) == ["model", "permissions", "hooks", "statusLine"])
        // Existing events keep their position; new events are appended.
        #expect(merged["hooks"]?.objectMembers?.map(\.key) == ["PreToolUse", "Notification", "Stop", "SessionEnd"])
        // The user's PreToolUse group is untouched and ours comes after it.
        let pre = try #require(merged["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 2)
        #expect(pre[0] == original["hooks"]?["PreToolUse"]?.arrayValue?[0])
        #expect(pre[1]["hooks"]?.arrayValue?.first?["command"]?.stringValue == ours)
        #expect(pre[1]["hooks"]?.arrayValue?.first?["async"] == .bool(true))
        #expect(record.createdEvents == ["Stop", "SessionEnd"])
        #expect(!record.createdHooksKey)
    }

    @Test func mergeThenUnmergeRoundTripsExactly() throws {
        let original = try OrderedJSON.parse(userSettings)
        let (merged, record) = try HookMerger.merge(original, entries: entries)
        let restored = HookMerger.unmerge(merged, record: record)
        #expect(restored == original)
        #expect(OrderedJSON.print(restored) == userSettings)
    }

    @Test func roundTripWithoutHooksKey() throws {
        let text = "{\n  \"model\": \"opus\"\n}\n"
        let original = try OrderedJSON.parse(text)
        let (merged, record) = try HookMerger.merge(original, entries: entries)
        #expect(record.createdHooksKey)
        #expect(OrderedJSON.print(HookMerger.unmerge(merged, record: record)) == text)
    }

    @Test func roundTripKeepsAnEmptyHooksObjectTheUserHad() throws {
        let text = "{\n  \"hooks\": {}\n}\n"
        let original = try OrderedJSON.parse(text)
        let (merged, record) = try HookMerger.merge(original, entries: entries)
        #expect(OrderedJSON.print(HookMerger.unmerge(merged, record: record)) == text)
    }

    @Test func roundTripKeepsAnEmptyEventArrayTheUserHad() throws {
        let text = "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
        let original = try OrderedJSON.parse(text)
        let (merged, record) = try HookMerger.merge(original, entries: entries)
        #expect(!record.createdEvents.contains("Stop"))
        #expect(OrderedJSON.print(HookMerger.unmerge(merged, record: record)) == text)
    }

    @Test func mergeIsIdempotent() throws {
        let original = try OrderedJSON.parse(userSettings)
        let (once, r1) = try HookMerger.merge(original, entries: entries)
        let (twice, _) = try HookMerger.merge(once, entries: entries, record: r1)
        #expect(once == twice)
    }

    @Test func unmergeWithoutRecordRemovesOnlyOurs() throws {
        let original = try OrderedJSON.parse(userSettings)
        let (merged, _) = try HookMerger.merge(original, entries: entries)
        let restored = HookMerger.unmerge(merged, record: nil)
        #expect(restored == original)
    }

    @Test func handlerSharedWithUserHooksInOneGroupIsRemovedAlone() throws {
        // Someone hand-added our command into their own group.
        let text = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say hi"},{"type":"command","command":"\(ours.replacingOccurrences(of: "\"", with: "\\\""))","async":true}]}]}}
        """
        let value = try OrderedJSON.parse(text)
        let cleaned = HookMerger.unmerge(value, record: nil)
        #expect(cleaned["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1)
        #expect(cleaned["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "say hi")
    }

    @Test func refusesNonObjects() {
        #expect(throws: HookMerger.MergeError.self) { try HookMerger.merge(.array([]), entries: entries) }
        #expect(throws: HookMerger.MergeError.self) { try HookMerger.merge(try OrderedJSON.parse(#"{"hooks":[]}"#), entries: entries) }
    }

    @Test func approvalEntryIsSynchronousWithTimeout() {
        let entry = HookMerger.Entry(event: "PermissionRequest", command: ours + " permission 45", async: false, timeout: 60)
        #expect(entry.handler["async"] == nil)
        #expect(entry.handler["timeout"] == .number("60"))
    }

    @Test func diffShowsOnlyChanges() {
        let diff = LineDiff.diff("a\nb\nc", "a\nb\nx\nc")
        #expect(diff == [.same("a"), .same("b"), .added("x"), .same("c")])
        #expect(LineDiff.condensed(LineDiff.diff("same", "same")).isEmpty)
    }
}

@MainActor
struct InstallerFileTests {
    final class TempInstaller: JSONHookInstaller {
        let dir: URL
        init(dir: URL, events: [String] = ["PreToolUse", "Stop"]) {
            self.dir = dir
            super.init(providerID: "test", events: events)
        }
        override var fileURL: URL { dir.appendingPathComponent("settings.json") }
        override var recordDirectory: URL { dir }
    }

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("di4m-inst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installBacksUpAndUninstallRestoresExactly() throws {
        let dir = try tempDir()
        let installer = TempInstaller(dir: dir)
        let original = "{\n    \"theme\": \"dark\",\n    \"hooks\": {\n        \"Stop\": []\n    }\n}\n"
        try original.write(to: installer.fileURL, atomically: true, encoding: .utf8)

        #expect(installer.status(lastEventAt: nil) == .notInstalled)
        let plan = try installer.planInstall(approvalTimeout: nil)
        #expect(!plan.diff.isEmpty)
        try installer.apply(plan)
        let written = try String(contentsOf: installer.fileURL, encoding: .utf8)
        #expect(written.contains("    \"theme\""), "keeps the file's 4-space indent")
        #expect(installer.status(lastEventAt: nil) == .installed)
        #expect(installer.status(lastEventAt: Date().addingTimeInterval(5)) == .receivingEvents)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".dynamicisland4mac-backup-") }
        #expect(backups.count == 1)

        try installer.apply(try installer.planUninstall())
        #expect(try String(contentsOf: installer.fileURL, encoding: .utf8) == original)
        #expect(installer.status(lastEventAt: nil) == .notInstalled)
    }

    @Test func createsAndDeletesAFileItOwns() throws {
        let dir = try tempDir()
        let installer = TempInstaller(dir: dir)
        let plan = try installer.planInstall(approvalTimeout: nil)
        #expect(plan.originalText == nil)
        try installer.apply(plan)
        #expect(FileManager.default.fileExists(atPath: installer.fileURL.path))
        let removal = try installer.planUninstall()
        #expect(removal.newText == nil)
        try installer.apply(removal)
        #expect(!FileManager.default.fileExists(atPath: installer.fileURL.path))
    }

    @Test func togglingApprovalsReplacesInsteadOfDuplicating() throws {
        let dir = try tempDir()
        let installer = TempInstaller(dir: dir)
        try installer.apply(try installer.planInstall(approvalTimeout: nil))
        try installer.apply(try installer.planInstall(approvalTimeout: 30))
        #expect(installer.approvalEntryInstalled())
        try installer.apply(try installer.planInstall(approvalTimeout: 60))
        let root = try OrderedJSON.parse(try String(contentsOf: installer.fileURL, encoding: .utf8))
        #expect(HookMerger.ourCommands(root)["PermissionRequest"]?.count == 1)
        try installer.apply(try installer.planInstall(approvalTimeout: nil))
        #expect(!installer.approvalEntryInstalled())
    }

    @Test func refusesToWriteIfFileChangedAfterDiff() throws {
        let dir = try tempDir()
        let installer = TempInstaller(dir: dir)
        try "{}\n".write(to: installer.fileURL, atomically: true, encoding: .utf8)
        let plan = try installer.planInstall(approvalTimeout: nil)
        try "{\"changed\": true}\n".write(to: installer.fileURL, atomically: true, encoding: .utf8)
        #expect(throws: JSONHookInstaller.ApplyError.self) { try installer.apply(plan) }
        #expect(try String(contentsOf: installer.fileURL, encoding: .utf8) == "{\"changed\": true}\n")
    }

    @Test func detectsInlineTOMLHooks() {
        #expect(CodexInstaller.tomlDeclaresHooks("model = \"x\"\n[[hooks.PreToolUse]]\nmatcher = \"^Bash$\"\n"))
        #expect(CodexInstaller.tomlDeclaresHooks("[hooks]\n"))
        #expect(CodexInstaller.tomlDeclaresHooks("  [[hooks.Stop.hooks]]\n"))
        #expect(!CodexInstaller.tomlDeclaresHooks("# [hooks]\n[features]\nhooks = true\n"))
        #expect(!CodexInstaller.tomlDeclaresHooks("[hooksmith]\n"))
        #expect(!CodexInstaller.tomlDeclaresHooks("[mcp_servers.hooks]\n"))
    }
}

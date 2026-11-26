import AppKit
import Foundation
import Testing
@testable import DynamicIsland4Mac

struct ModuleLogicTests {
    @Test func countdownLabels() {
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(1800)
        #expect(CountdownText.label(now: start.addingTimeInterval(-12 * 60), start: start, end: end) == "in 12m")
        #expect(CountdownText.label(now: start.addingTimeInterval(-11.5 * 60), start: start, end: end) == "in 12m")
        #expect(CountdownText.label(now: start.addingTimeInterval(-90 * 60), start: start, end: end) == "in 1h 30m")
        #expect(CountdownText.label(now: start.addingTimeInterval(60), start: start, end: end) == "now")
        #expect(CountdownText.label(now: end.addingTimeInterval(1), start: start, end: end) == "ended")
    }

    @Test func batteryTimeFormatting() {
        #expect(BatteryExpandedView.format(45) == "45m")
        #expect(BatteryExpandedView.format(125) == "2h 5m")
    }

    @Test func toolSymbols() {
        #expect(AgentStatusIndicator.symbol(forTool: "Bash") == "terminal")
        #expect(AgentStatusIndicator.symbol(forTool: "apply_patch") == "pencil")
        #expect(AgentStatusIndicator.symbol(forTool: "mcp__github__create_issue") == "puzzlepiece.extension")
        #expect(AgentStatusIndicator.symbol(forTool: "SomethingNew") == "wrench.and.screwdriver")
    }

    @Test func toolSummaries() {
        #expect(ToolSummary.detail(tool: "Bash", input: ["command": "ls -la"]) == "ls -la")
        #expect(ToolSummary.detail(tool: "Read", input: ["file_path": "/a/b/c.swift"]) == "c.swift")
        #expect(ToolSummary.detail(tool: "X", input: ["unknown": 1]) == nil)
        #expect(ToolSummary.truncate(String(repeating: "a", count: 300)).count == 140)
    }
}

@MainActor
struct CoreAnimationViewTests {
    @Test func waveformAnimatesOnlyWhilePlaying() {
        let view = WaveformLayerView(barCount: 4)
        view.frame = NSRect(x: 0, y: 0, width: 22, height: 14)
        view.layout()
        let bars = view.layer?.sublayers ?? []
        #expect(bars.count == 4)
        view.update(color: .white, animating: true)
        #expect(bars.allSatisfy { $0.animation(forKey: "bounce") != nil })
        view.update(color: .white, animating: false)
        #expect(bars.allSatisfy { $0.animation(forKey: "bounce") == nil })
    }

    @Test func pulseRunsOnTheLayer() {
        let view = PulsingDotView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        view.update(color: .white, animating: true)
        #expect(view.layer?.sublayers?.first?.animation(forKey: "pulse") != nil)
    }
}

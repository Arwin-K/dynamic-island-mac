import Observation
import SwiftUI

/// A focus (pomodoro) timer: a draining progress ring, pause / resume, +5 min, presets, and
/// a count of sessions finished today. Off by default; turn it on in Settings → Modules.
///
/// The README's "Write your own module in 5 minutes" shows a minimal version of this module.
///
/// Efficiency: the ring drains via one Core Animation animation over the whole remaining time
/// (run by the render server), and the module schedules a single wake-up for the end, so a
/// running timer costs the app almost nothing.
@MainActor
@Observable
final class FocusTimerModule: IslandModule {
    let id = "focusTimer"
    let displayName = "Focus Timer"
    let symbolName = "timer"
    let priority = 30
    let enabledByDefault = false
    let showsInExpandedWhenIdle = true

    @ObservationIgnored let context: ModuleContext
    /// When the running session ends (nil when idle or paused).
    private(set) var endsAt: Date?
    /// Seconds left while paused.
    private(set) var pausedRemaining: TimeInterval?
    /// Length of the current session, for the ring.
    private(set) var sessionLength: TimeInterval = 25 * 60
    @ObservationIgnored private var finish: DispatchWorkItem?

    init(context: ModuleContext) {
        self.context = context
    }

    static let presets: [Double] = [15, 25, 50]

    /// The selected length in minutes (a setting, stored by the context).
    var minutes: Double { context.double("minutes", default: 25) }

    var isRunning: Bool { endsAt != nil }
    var isPaused: Bool { pausedRemaining != nil }
    /// Live activity while running or paused: it gets the compact island.
    var isActive: Bool { isRunning || isPaused }

    /// Sessions completed today.
    var completedToday: Int {
        context.string("completedDay", default: "") == Self.today ? Int(context.double("completedCount", default: 0)) : 0
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endsAt { return max(0, endsAt.timeIntervalSince(date)) }
        return minutes * 60
    }

    // MARK: Controls

    func selectPreset(_ minutes: Double) {
        context.set("minutes", minutes)
    }

    /// Named `beginSession`, not `start`: `start()` is the module lifecycle hook the app calls
    /// whenever the module is enabled (including at launch).
    func beginSession() {
        sessionLength = minutes * 60
        pausedRemaining = nil
        schedule(remaining: sessionLength)
    }

    func pause() {
        guard let endsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSinceNow)
        self.endsAt = nil
        finish?.cancel()
    }

    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        schedule(remaining: pausedRemaining)
    }

    func addFiveMinutes() {
        sessionLength += 300
        if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + 300
        } else if let endsAt {
            schedule(remaining: endsAt.timeIntervalSinceNow + 300)
        }
    }

    func reset() {
        finish?.cancel()
        endsAt = nil
        pausedRemaining = nil
    }

    /// One wake-up at the end of the session; nothing ticks in between.
    private func schedule(remaining: TimeInterval) {
        finish?.cancel()
        endsAt = Date().addingTimeInterval(remaining)
        let work = DispatchWorkItem { [weak self] in self?.timerFinished() }
        finish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func timerFinished() {
        endsAt = nil
        pausedRemaining = nil
        let count = completedToday + 1
        context.set("completedDay", Self.today)
        context.set("completedCount", Double(count))
        context.alert(feedback: .agentDone, duration: 6) {
            FocusDoneAlert(count: count)
        }
    }

    func stop() { reset() }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: Views

    func compactLeading() -> some View {
        FocusRing(progress: remaining() / max(sessionLength, 1), endsAt: endsAt, lineWidth: 2.5)
            .frame(width: 16, height: 16)
            .islandMatched("ring", module: id)
            .accessibilityHidden(true)
    }

    func compactTrailing() -> some View {
        FocusTimeText(module: self, size: nil)
    }

    func expanded() -> some View {
        FocusTimerExpandedView(module: self)
    }

    func settingsView() -> AnyView {
        AnyView(ValueSlider(title: "Default length", value: context.doubleBinding("minutes", default: 25),
                            range: 5...90, step: 5, format: "%.0f min"))
    }

    /// Settings preview: a session in progress.
    static func preview(context: ModuleContext) -> FocusTimerModule {
        let module = FocusTimerModule(context: context)
        module.sessionLength = 25 * 60
        module.pausedRemaining = 17 * 60 + 42
        return module
    }
}

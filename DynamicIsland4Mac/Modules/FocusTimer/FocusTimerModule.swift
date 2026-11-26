import Observation
import SwiftUI

/// The example from the README's "Write your own module in 5 minutes": a focus timer.
/// Off by default; turn it on in Settings → Modules.
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
    private(set) var endsAt: Date?
    @ObservationIgnored private var finish: DispatchWorkItem?

    init(context: ModuleContext) {
        self.context = context
    }

    // A setting, stored for us by the context.
    var minutes: Double { context.double("minutes", default: 25) }

    // Live activity while the timer runs: it gets the compact island.
    var isActive: Bool { endsAt != nil }

    func startTimer() {
        endsAt = Date().addingTimeInterval(minutes * 60)
        let work = DispatchWorkItem { [weak self] in self?.timerFinished() }
        finish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60, execute: work)
    }

    func cancelTimer() {
        finish?.cancel()
        endsAt = nil
    }

    private func timerFinished() {
        endsAt = nil
        context.alert(feedback: .agentDone) {
            Label("Focus session done", systemImage: "checkmark.circle.fill")
        }
    }

    func stop() { cancelTimer() }

    // Left of the notch.
    func compactLeading() -> some View {
        Image(systemName: "timer")
            .islandMatched("icon", module: id)
    }

    // Right of the notch.
    func compactTrailing() -> some View {
        if let endsAt {
            Text(timerInterval: Date()...endsAt, countsDown: true)
                .monospacedDigit()
                .frame(width: 44)
        }
    }

    // The open island.
    func expanded() -> some View {
        HStack(spacing: 16) {
            Image(systemName: "timer")
                .font(.system(size: 30))
                .islandMatched("icon", module: id)
            if let endsAt {
                Text(timerInterval: Date()...endsAt, countsDown: true)
                    .font(.system(size: 28, weight: .bold).monospacedDigit())
                Button("Stop") { self.cancelTimer() }
            } else {
                Button("Start \(Int(minutes)) min focus") { self.startTimer() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Settings → Modules → Focus Timer.
    func settingsView() -> AnyView {
        AnyView(ValueSlider(title: "Length", value: context.doubleBinding("minutes", default: 25),
                            range: 5...90, step: 5, format: "%.0f min"))
    }
}

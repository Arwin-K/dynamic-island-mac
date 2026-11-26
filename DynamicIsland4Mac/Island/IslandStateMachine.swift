import Foundation

/// The four states of the island.
enum IslandState: String, Equatable, CaseIterable {
    /// Exactly the notch. Invisible against the hardware.
    case collapsed
    /// Small extensions on either side of the notch showing a live activity.
    case compact
    /// The full panel.
    case expanded
    /// A brief, attention-grabbing expansion for an event. Collapses back after a timeout.
    case alert
}

/// Pure transition logic, kept separate from `IslandViewModel` so it can be unit tested
/// without windows or timers.
///
/// Rules:
/// * The *resting* state is `compact` when some module has a live activity, else `collapsed`.
/// * `open()` always goes to `expanded`. `close()` goes back to `alert` if an alert is still
///   pending, else to the resting state.
/// * An alert shows as `alert` unless the island is already `expanded`, in which case it stays
///   expanded (the expanded view shows the alerting module instead).
/// * Live activity changes only move between `collapsed` and `compact`; they never close an
///   open island or interrupt an alert.
struct IslandStateMachine: Equatable {
    private(set) var state: IslandState = .collapsed
    private(set) var hasLiveActivity = false
    private(set) var alertPending = false

    var resting: IslandState { hasLiveActivity ? .compact : .collapsed }
    var isOpen: Bool { state == .expanded }

    mutating func open() {
        state = .expanded
    }

    mutating func close() {
        state = alertPending ? .alert : resting
    }

    mutating func beginAlert() {
        alertPending = true
        if state != .expanded { state = .alert }
    }

    mutating func endAlert() {
        alertPending = false
        if state == .alert { state = resting }
    }

    mutating func setLiveActivity(_ active: Bool) {
        hasLiveActivity = active
        if state == .collapsed || state == .compact { state = resting }
    }
}
